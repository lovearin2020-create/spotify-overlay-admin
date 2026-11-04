-- Spotify Overlay 2.1.0 Max 선공개
-- 1-schema.sql, 2-schema.sql 을 실행한 뒤에 실행합니다. 여러 번 실행해도 괜찮습니다.

-- 프로그램이 "내 버전이 정식 공개되었는지" 묻는 함수 (early, stable, none)
create or replace function public.release_channel(p_version text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select channel from public.releases where version = p_version), 'none')
$$;
revoke all on function public.release_channel(text) from public, anon;
grant execute on function public.release_channel(text) to authenticated;

-- 2.1.0 을 Max 선공개로 등록합니다.
-- 2.0.0 을 쓰는 Max 사용자에게는 설정 창에 "새 버전 2.1.0" 알림이 뜨고, 받기를 누르면 오픈채팅이 열립니다.
insert into public.releases (version, channel, download_url, notes, kind)
values ('2.1.0', 'early', 'https://open.kakao.com/o/sMGDBxVi',
        '곡이 바뀔 때만 잠깐 뜨는 카드, 번역 줄, 이 곡만 싱크, 단어 단위 가사, 방송용 화면(OBS)이 생겼습니다. 오픈채팅에서 설치 파일을 받을 수 있습니다.', 'link')
on conflict (version) do nothing;
