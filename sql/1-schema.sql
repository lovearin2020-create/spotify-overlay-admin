-- ════════════════════════════════════════════════════════════════
-- Spotify Overlay 요금제 서버 (Supabase)
-- Supabase 대시보드 > SQL Editor 에 이 파일 전체를 붙여넣고 Run 을 누르면 됩니다.
-- 여러 번 실행해도 괜찮습니다.
-- ════════════════════════════════════════════════════════════════

-- ───────── 사용자 요금제 ─────────
create table if not exists public.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  plan       text not null default 'free' check (plan in ('free', 'pro', 'max')),
  plan_until timestamptz,                 -- 이 시각까지 plan 을 쓸 수 있음 (null 이면 기한 없음)
  note       text,                        -- 관리용 메모
  created_at timestamptz not null default now()
);

-- ───────── 프로모션 키 ─────────
create table if not exists public.promo_codes (
  code       text primary key,            -- 예: SPOV-ABCD-EFGH-JKLM
  plan       text not null check (plan in ('pro', 'max')),
  days       int  not null check (days > 0),   -- 키를 넣으면 이 기간만큼 요금제가 켜짐
  max_uses   int  not null default 1 check (max_uses > 0),
  used_count int  not null default 0,
  expires_at timestamptz,                 -- 이 시각 뒤에는 키를 쓸 수 없음 (null 이면 기한 없음)
  note       text,                        -- 누구에게 줬는지 등
  created_at timestamptz not null default now()
);

create table if not exists public.promo_redemptions (
  code        text not null references public.promo_codes(code) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  redeemed_at timestamptz not null default now(),
  primary key (code, user_id)
);

-- ───────── 무료 플랜 하루 곡 수 ─────────
create table if not exists public.daily_tracks (
  user_id  uuid not null references auth.users(id) on delete cascade,
  day      date not null,                 -- 한국 시간 기준 날짜
  track_id text not null,
  primary key (user_id, day, track_id)
);

-- ───────── 업데이트 안내 (Max 는 early 채널도 받음) ─────────
create table if not exists public.releases (
  version      text primary key,          -- 예: 2.1.0
  channel      text not null default 'stable' check (channel in ('stable', 'early')),
  download_url text not null,
  notes        text,
  published_at timestamptz not null default now()
);

-- 모든 표는 프로그램에서 직접 읽거나 쓰지 못하게 막고, 아래 함수로만 다룹니다.
alter table public.profiles          enable row level security;
alter table public.promo_codes       enable row level security;
alter table public.promo_redemptions enable row level security;
alter table public.daily_tracks      enable row level security;
alter table public.releases          enable row level security;

-- ───────── 가입하면 요금제 줄을 만듭니다 ─────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id, email) values (new.id, new.email)
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ───────── 지금 쓸 수 있는 요금제 ─────────
create or replace function public.effective_plan(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((
    select case when p.plan <> 'free' and (p.plan_until is null or p.plan_until > now()) then p.plan else 'free' end
    from public.profiles p where p.user_id = p_user
  ), 'free')
$$;

create or replace function public.kst_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Seoul')::date
$$;

-- 프로그램이 켜질 때 부르는 함수: 요금제, 남은 기간, 오늘 들은 곡 수
create or replace function public.get_entitlement()
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  pr  public.profiles;
  eff text;
  used int;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  select * into pr from public.profiles where user_id = uid;
  if not found then
    insert into public.profiles (user_id, email) select uid, email from auth.users where id = uid
    on conflict (user_id) do nothing;
    select * into pr from public.profiles where user_id = uid;
  end if;
  eff := public.effective_plan(uid);
  select count(*) into used from public.daily_tracks where user_id = uid and day = public.kst_today();
  return json_build_object(
    'plan', eff,
    'plan_until', case when eff = 'free' then null else pr.plan_until end,
    'email', pr.email,
    'daily_limit', 10,
    'daily_used', used,
    'server_time', now()
  );
end $$;

-- 무료 플랜: 새 곡을 틀 때마다 부르는 함수. 오늘 10곡을 넘으면 allowed = false
create or replace function public.register_track(p_track_id text)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  eff text;
  today date := public.kst_today();
  used int;
  seen boolean;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_track_id is null or length(p_track_id) = 0 or length(p_track_id) > 100 then raise exception 'bad_track'; end if;
  eff := public.effective_plan(uid);
  if eff <> 'free' then
    return json_build_object('allowed', true, 'plan', eff, 'daily_used', 0, 'daily_limit', 10);
  end if;
  -- 같은 사용자의 요청이 동시에 와도 10곡을 넘지 않게 잠급니다.
  perform pg_advisory_xact_lock(hashtext(uid::text));
  select exists(select 1 from public.daily_tracks where user_id = uid and day = today and track_id = p_track_id) into seen;
  select count(*) into used from public.daily_tracks where user_id = uid and day = today;
  if seen then
    return json_build_object('allowed', true, 'plan', eff, 'daily_used', used, 'daily_limit', 10);
  end if;
  if used >= 10 then
    return json_build_object('allowed', false, 'plan', eff, 'daily_used', used, 'daily_limit', 10);
  end if;
  insert into public.daily_tracks (user_id, day, track_id) values (uid, today, p_track_id);
  -- 오래된 기록 정리
  delete from public.daily_tracks where user_id = uid and day < today - 7;
  return json_build_object('allowed', true, 'plan', eff, 'daily_used', used + 1, 'daily_limit', 10);
end $$;

-- 프로모션 키 사용
--  같은 요금제를 쓰는 중이면 남은 기간 뒤에 이어 붙이고,
--  Pro 를 쓰는 중에 Max 키를 넣으면 지금부터 Max 로 바뀝니다.
--  Max 를 쓰는 중에 Pro 키를 넣으면 거절합니다. (키는 사용 처리되지 않으니 Max 가 끝난 뒤에 쓰면 됩니다)
create or replace function public.redeem_promo(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c   public.promo_codes;
  pr  public.profiles;
  code_norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  eff text;
  base timestamptz;
  new_until timestamptz;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  select * into c from public.promo_codes
    where upper(regexp_replace(code, '[^A-Za-z0-9]', '', 'g')) = code_norm
    for update;
  if not found then return json_build_object('ok', false, 'error', 'not_found'); end if;
  if c.expires_at is not null and c.expires_at < now() then return json_build_object('ok', false, 'error', 'expired'); end if;
  if exists(select 1 from public.promo_redemptions where code = c.code and user_id = uid) then
    return json_build_object('ok', false, 'error', 'already_used');
  end if;
  if c.used_count >= c.max_uses then return json_build_object('ok', false, 'error', 'used_up'); end if;

  select * into pr from public.profiles where user_id = uid for update;
  eff := public.effective_plan(uid);
  if eff = 'max' and c.plan = 'pro' then
    return json_build_object('ok', false, 'error', 'lower_plan', 'plan', eff, 'plan_until', pr.plan_until);
  end if;
  if eff = c.plan and pr.plan_until is null then
    return json_build_object('ok', false, 'error', 'already_unlimited', 'plan', eff);
  end if;

  base := case when eff = c.plan and pr.plan_until > now() then pr.plan_until else now() end;
  new_until := base + make_interval(days => c.days);

  update public.profiles set plan = c.plan, plan_until = new_until where user_id = uid;
  update public.promo_codes set used_count = used_count + 1 where code = c.code;
  insert into public.promo_redemptions (code, user_id) values (c.code, uid);
  return json_build_object('ok', true, 'plan', c.plan, 'plan_until', new_until, 'days', c.days);
end $$;

-- 업데이트 안내: 가장 최신 버전 하나 (Max 는 early 포함)
create or replace function public.latest_release()
returns json language sql stable security definer set search_path = public as $$
  select coalesce((
    select json_build_object('version', r.version, 'channel', r.channel, 'download_url', r.download_url, 'notes', r.notes)
    from public.releases r
    where r.channel = 'stable' or (r.channel = 'early' and public.effective_plan(auth.uid()) = 'max')
    order by string_to_array(regexp_replace(r.version, '[^0-9.]', '', 'g'), '.')::int[] desc
    limit 1
  ), 'null'::json)
$$;

-- ───────── 관리용: 프로모션 키 만들기 ─────────
-- SQL Editor 에서 실행합니다. 예)
--   select * from admin_make_codes('pro', 30, 5);            -- Pro 30일 키 5개 (키마다 1명)
--   select * from admin_make_codes('max', 365, 1, 1, '친구 선물');
--   select * from admin_make_codes('pro', 7, 1, 100, '이벤트', now() + interval '14 days');  -- 100명이 쓸 수 있는 키 1개
create or replace function public.admin_make_codes(
  p_plan text, p_days int, p_count int default 1, p_max_uses int default 1,
  p_note text default null, p_expires_at timestamptz default null)
returns table (code text, plan text, days int, max_uses int, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 헷갈리는 0, O, 1, I 는 뺐습니다
  k text;
  i int;
  n int := 0;
begin
  while n < p_count loop
    k := 'SPOV-';
    for i in 1..12 loop
      k := k || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
      if i % 4 = 0 and i < 12 then k := k || '-'; end if;
    end loop;
    begin
      insert into public.promo_codes (code, plan, days, max_uses, note, expires_at)
        values (k, p_plan, p_days, p_max_uses, p_note, p_expires_at);
      n := n + 1;
      code := k; plan := p_plan; days := p_days; max_uses := p_max_uses; expires_at := p_expires_at;
      return next;
    exception when unique_violation then
      -- 같은 키가 이미 있으면 다시 만듭니다.
    end;
  end loop;
end $$;

-- 관리용 함수는 프로그램(로그인한 사용자)이 부를 수 없게 막습니다. SQL Editor 에서는 그대로 쓸 수 있습니다.
revoke all on function public.admin_make_codes(text, int, int, int, text, timestamptz) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.effective_plan(uuid) from public, anon, authenticated;

-- 프로그램이 부를 수 있는 함수
revoke all on function public.get_entitlement() from public, anon;
revoke all on function public.register_track(text) from public, anon;
revoke all on function public.redeem_promo(text) from public, anon;
revoke all on function public.latest_release() from public, anon;
grant execute on function public.get_entitlement() to authenticated;
grant execute on function public.register_track(text) to authenticated;
grant execute on function public.redeem_promo(text) to authenticated;
grant execute on function public.latest_release() to authenticated;
