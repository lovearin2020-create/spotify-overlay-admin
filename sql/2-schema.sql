-- Spotify Overlay 2.1 서버 추가분: 동시 사용 기기 제한, 업데이트 파일, 피드백, 관리자 페이지
-- 처음 schema.sql 을 실행한 뒤에 이 파일을 실행합니다. 여러 번 실행해도 괜찮습니다.

-- 관리자
create table if not exists public.admins (
  email text primary key
);
alter table public.admins enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.admins a join auth.users u on lower(u.email) = lower(a.email)
    where u.id = auth.uid() and u.email_confirmed_at is not null
  )
$$;

-- 동시 사용 기기 (계정 하나를 같은 시간에 2대까지)
create table if not exists public.devices (
  user_id    uuid not null references auth.users(id) on delete cascade,
  device_id  text not null,
  name       text,
  revoked    boolean not null default false,
  last_seen  timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.devices enable row level security;

create or replace function public.device_limit() returns int language sql immutable as $$ select 2 $$;

-- 프로그램이 5분마다 부르는 함수. 12분 동안 소식이 없는 기기는 꺼진 것으로 봅니다.
create or replace function public.heartbeat(p_device text, p_name text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  d public.devices;
  active int;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_device is null or length(p_device) < 8 or length(p_device) > 64 then raise exception 'bad_device'; end if;
  perform pg_advisory_xact_lock(hashtext('dev' || uid::text));
  select * into d from public.devices where user_id = uid and device_id = p_device;
  if found and d.revoked then
    return json_build_object('allowed', false, 'reason', 'kicked', 'limit', public.device_limit(), 'devices', public.my_devices_json(uid, p_device));
  end if;
  if found and d.last_seen > now() - interval '12 minutes' then
    update public.devices set last_seen = now(), name = coalesce(left(p_name, 60), name) where user_id = uid and device_id = p_device;
    return json_build_object('allowed', true, 'limit', public.device_limit());
  end if;
  select count(*) into active from public.devices
    where user_id = uid and device_id <> p_device and not revoked and last_seen > now() - interval '12 minutes';
  if active >= public.device_limit() then
    return json_build_object('allowed', false, 'reason', 'too_many', 'limit', public.device_limit(), 'devices', public.my_devices_json(uid, p_device));
  end if;
  insert into public.devices (user_id, device_id, name, revoked, last_seen) values (uid, p_device, left(p_name, 60), false, now())
    on conflict (user_id, device_id) do update set last_seen = now(), revoked = false, name = coalesce(excluded.name, devices.name);
  return json_build_object('allowed', true, 'limit', public.device_limit());
end $$;

create or replace function public.my_devices_json(p_user uuid, p_except text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('name', coalesce(name, '이름 없는 컴퓨터'), 'last_seen', last_seen) order by last_seen desc), '[]'::json)
  from public.devices
  where user_id = p_user and device_id <> p_except and not revoked and last_seen > now() - interval '12 minutes'
$$;

-- "이 컴퓨터에서 쓰기": 다른 기기를 모두 로그아웃시키고 이 기기를 씁니다.
create or replace function public.take_over_device(p_device text, p_name text default null)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_device is null or length(p_device) < 8 or length(p_device) > 64 then raise exception 'bad_device'; end if;
  update public.devices set revoked = true where user_id = uid and device_id <> p_device;
  insert into public.devices (user_id, device_id, name, revoked, last_seen) values (uid, p_device, left(p_name, 60), false, now())
    on conflict (user_id, device_id) do update set last_seen = now(), revoked = false;
  return json_build_object('allowed', true, 'limit', public.device_limit());
end $$;

-- 로그아웃할 때: 이 기기 자리를 비웁니다.
create or replace function public.release_device(p_device text)
returns void language sql security definer set search_path = public as $$
  delete from public.devices where user_id = auth.uid() and device_id = p_device
$$;

-- 업데이트 파일 정보
alter table public.releases add column if not exists kind text not null default 'link';  -- asar | installer | link
alter table public.releases add column if not exists sha256 text;
alter table public.releases add column if not exists size bigint;

create or replace function public.latest_release()
returns json language sql stable security definer set search_path = public as $$
  select coalesce((
    select json_build_object('version', r.version, 'channel', r.channel, 'download_url', r.download_url, 'notes', r.notes,
                             'kind', r.kind, 'sha256', r.sha256, 'size', r.size)
    from public.releases r
    where r.channel = 'stable' or (r.channel = 'early' and public.effective_plan(auth.uid()) = 'max')
    order by string_to_array(regexp_replace(r.version, '[^0-9.]', '', 'g'), '.')::int[] desc
    limit 1
  ), 'null'::json)
$$;

-- 피드백
create table if not exists public.feedback (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users(id) on delete set null,
  email      text,
  kind       text not null default 'other',   -- bug | idea | other
  message    text not null,
  log        text,
  app_version text,
  plan       text,
  resolved   boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;

create or replace function public.send_feedback(p_kind text, p_message text, p_log text default null, p_version text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  n int;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_message is null or length(trim(p_message)) = 0 then return json_build_object('ok', false, 'error', 'empty'); end if;
  select count(*) into n from public.feedback where user_id = uid and created_at > now() - interval '1 day';
  if n >= 10 then return json_build_object('ok', false, 'error', 'too_many'); end if;
  insert into public.feedback (user_id, email, kind, message, log, app_version, plan)
    select uid, u.email, case when p_kind in ('bug', 'idea', 'other') then p_kind else 'other' end,
           left(p_message, 4000), left(p_log, 60000), left(p_version, 20), public.effective_plan(uid)
    from auth.users u where u.id = uid;
  return json_build_object('ok', true);
end $$;

-- ───────── 관리자 페이지용 함수 (관리자만 부를 수 있음) ─────────

create or replace function public.admin_check() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
end $$;

create or replace function public.admin_stats()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_check();
  return json_build_object(
    'users', (select count(*) from public.profiles),
    'pro', (select count(*) from public.profiles p where public.effective_plan(p.user_id) = 'pro'),
    'max', (select count(*) from public.profiles p where public.effective_plan(p.user_id) = 'max'),
    'new_7d', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'active_now', (select count(distinct user_id) from public.devices where not revoked and last_seen > now() - interval '12 minutes'),
    'open_feedback', (select count(*) from public.feedback where not resolved),
    'unused_codes', (select count(*) from public.promo_codes where used_count < max_uses and (expires_at is null or expires_at > now()))
  );
end $$;

create or replace function public.admin_list_users(p_search text default null, p_limit int default 100)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_check();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select p.email, p.plan, p.plan_until, public.effective_plan(p.user_id) as effective, p.note, p.created_at,
           (select max(last_seen) from public.devices d where d.user_id = p.user_id) as last_seen,
           (select count(*) from public.devices d where d.user_id = p.user_id and not d.revoked and d.last_seen > now() - interval '12 minutes') as active_devices
    from public.profiles p
    where p_search is null or p_search = '' or p.email ilike '%' || p_search || '%'
    order by p.created_at desc
    limit greatest(1, least(p_limit, 500))
  ) x), '[]'::json);
end $$;

create or replace function public.admin_set_plan(p_email text, p_plan text, p_days int default null)
returns json language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.admin_check();
  if p_plan not in ('free', 'pro', 'max') then raise exception 'bad_plan'; end if;
  update public.profiles set plan = p_plan,
    plan_until = case when p_plan = 'free' then null when p_days is null then null else now() + make_interval(days => p_days) end
  where lower(email) = lower(p_email);
  get diagnostics n = row_count;
  return json_build_object('ok', n > 0);
end $$;

create or replace function public.admin_reset_devices(p_email text)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  delete from public.devices d using public.profiles p where d.user_id = p.user_id and lower(p.email) = lower(p_email);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_create_codes(p_plan text, p_days int, p_count int default 1, p_max_uses int default 1,
  p_note text default null, p_valid_days int default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  if p_count < 1 or p_count > 100 then raise exception 'bad_count'; end if;
  return (select json_agg(json_build_object('code', c.code, 'plan', c.plan, 'days', c.days, 'max_uses', c.max_uses, 'expires_at', c.expires_at))
    from public.admin_make_codes(p_plan, p_days, p_count, p_max_uses, p_note,
      case when p_valid_days is null then null else now() + make_interval(days => p_valid_days) end) c);
end $$;

create or replace function public.admin_list_codes(p_limit int default 100)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_check();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select c.code, c.plan, c.days, c.max_uses, c.used_count, c.expires_at, c.note, c.created_at,
           (select string_agg(p.email, ', ') from public.promo_redemptions r join public.profiles p on p.user_id = r.user_id where r.code = c.code) as used_by
    from public.promo_codes c order by c.created_at desc limit greatest(1, least(p_limit, 500))
  ) x), '[]'::json);
end $$;

create or replace function public.admin_delete_code(p_code text)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  delete from public.promo_codes where code = p_code;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_list_feedback(p_limit int default 100)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_check();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select id, email, kind, message, log, app_version, plan, resolved, created_at
    from public.feedback order by created_at desc limit greatest(1, least(p_limit, 300))
  ) x), '[]'::json);
end $$;

create or replace function public.admin_resolve_feedback(p_id bigint, p_resolved boolean default true)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  update public.feedback set resolved = p_resolved where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_list_releases()
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.admin_check();
  return coalesce((select json_agg(r order by r.published_at desc) from public.releases r), '[]'::json);
end $$;

create or replace function public.admin_publish_release(p_version text, p_channel text, p_url text, p_notes text default null,
  p_kind text default 'link', p_sha256 text default null, p_size bigint default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  if p_channel not in ('stable', 'early') then raise exception 'bad_channel'; end if;
  if p_kind not in ('asar', 'installer', 'link') then raise exception 'bad_kind'; end if;
  if p_url !~ '^https://' then raise exception 'bad_url'; end if;
  insert into public.releases (version, channel, download_url, notes, kind, sha256, size)
    values (p_version, p_channel, p_url, p_notes, p_kind, p_sha256, p_size)
  on conflict (version) do update set channel = excluded.channel, download_url = excluded.download_url, notes = excluded.notes,
    kind = excluded.kind, sha256 = excluded.sha256, size = excluded.size, published_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_delete_release(p_version text)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  delete from public.releases where version = p_version;
  return json_build_object('ok', true);
end $$;

-- 업데이트 파일 저장소 (누구나 받을 수 있고, 관리자만 올릴 수 있음)
insert into storage.buckets (id, name, public) values ('releases', 'releases', true) on conflict (id) do nothing;
drop policy if exists "releases admin insert" on storage.objects;
drop policy if exists "releases admin update" on storage.objects;
drop policy if exists "releases admin delete" on storage.objects;
create policy "releases admin insert" on storage.objects for insert to authenticated with check (bucket_id = 'releases' and public.is_admin());
create policy "releases admin update" on storage.objects for update to authenticated using (bucket_id = 'releases' and public.is_admin());
create policy "releases admin delete" on storage.objects for delete to authenticated using (bucket_id = 'releases' and public.is_admin());

-- 권한
revoke all on function public.my_devices_json(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_check() from public, anon;
do $$
declare f text;
begin
  foreach f in array array[
    'heartbeat(text, text)', 'take_over_device(text, text)', 'release_device(text)', 'send_feedback(text, text, text, text)', 'is_admin()',
    'admin_stats()', 'admin_list_users(text, int)', 'admin_set_plan(text, text, int)', 'admin_reset_devices(text)',
    'admin_create_codes(text, int, int, int, text, int)', 'admin_list_codes(int)', 'admin_delete_code(text)',
    'admin_list_feedback(int)', 'admin_resolve_feedback(bigint, boolean)', 'admin_list_releases()',
    'admin_publish_release(text, text, text, text, text, text, bigint)', 'admin_delete_release(text)', 'admin_check()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- 관리자 계정 (프로그램에 가입한 이메일)
insert into public.admins (email) values ('lovearin2020@gmail.com') on conflict (email) do nothing;
