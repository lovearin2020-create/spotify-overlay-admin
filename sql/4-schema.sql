-- Spotify Overlay 2.0.1: 새 기능 Max 선공개 스위치
-- 앞의 SQL(1, 2, 3)을 실행한 뒤에 실행합니다. 여러 번 실행해도 괜찮습니다.

create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);
alter table public.app_settings enable row level security;
insert into public.app_settings (key, value) values ('early_public', 'false') on conflict (key) do nothing;

-- 새 기능이 모두에게 공개되었는지 (false 면 Max 에서만 켜짐)
create or replace function public.early_features_public()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true' from public.app_settings where key = 'early_public'), false)
$$;

-- 관리자 페이지의 "모두에게 공개" 스위치
create or replace function public.admin_set_early_public(p_public boolean)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_check();
  insert into public.app_settings (key, value) values ('early_public', case when p_public then 'true' else 'false' end)
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true, 'public', p_public);
end $$;

revoke all on function public.early_features_public() from public, anon;
revoke all on function public.admin_set_early_public(boolean) from public, anon;
grant execute on function public.early_features_public() to authenticated;
grant execute on function public.admin_set_early_public(boolean) to authenticated;

-- 3번 SQL 에서 넣은 "2.1.0 오픈채팅 링크" 알림은 지웁니다. (업데이트 알림은 실제 업데이트 파일만)
delete from public.releases where version = '2.1.0' and kind = 'link';
