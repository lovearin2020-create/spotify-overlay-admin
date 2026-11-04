-- 5단계: 관리자 페이지에서 app.asar 를 다시 올릴 때(덮어쓰기) 필요한 읽기 권한
drop policy if exists "releases admin select" on storage.objects;
create policy "releases admin select" on storage.objects
  for select to authenticated
  using (bucket_id = 'releases' and public.is_admin());
