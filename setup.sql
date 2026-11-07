-- ふたりの家計簿 Ver.0.3: 既存の Ver.0.3 準備用 SQL 実行後に、一度だけ実行
-- Supabase SQL Editor の管理者権限で実行してください。
begin;

alter table public.transactions add column if not exists payment text not null default 'account';
alter table public.transactions add column if not exists person text;
alter table public.transactions drop constraint if exists transactions_payment_check;
alter table public.transactions add constraint transactions_payment_check check (payment in ('account','card','other'));

create table if not exists public.household_settings (
  household_id uuid primary key references public.households(id) on delete cascade,
  initial_balance numeric(12,0) not null default 0 check (initial_balance >= 0),
  monthly_budget numeric(12,0) not null default 250000 check (monthly_budget >= 0)
);

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.transactions enable row level security;
alter table public.household_settings enable row level security;

-- 以前のルールを整理して、意図したルールだけに統一する
 drop policy if exists "members can view households" on public.households;
 drop policy if exists "members can view transactions" on public.transactions;
 drop policy if exists "members can insert transactions" on public.transactions;
 drop policy if exists "users can update own transactions" on public.transactions;
 drop policy if exists "users can delete own transactions" on public.transactions;
 drop policy if exists "users can view own membership" on public.household_members;
 drop policy if exists "member read settings" on public.household_settings;
 drop policy if exists "member update settings" on public.household_settings;

create policy "members can view households" on public.households
for select to authenticated using (
 exists (select 1 from public.household_members m where m.household_id = id and m.user_id = (select auth.uid()))
);
create policy "users can view own membership" on public.household_members
for select to authenticated using (user_id = (select auth.uid()));
create policy "members can view transactions" on public.transactions
for select to authenticated using (
 exists (select 1 from public.household_members m where m.household_id = transactions.household_id and m.user_id = (select auth.uid()))
);
create policy "members can insert transactions" on public.transactions
for insert to authenticated with check (
 user_id = (select auth.uid()) and
 exists (select 1 from public.household_members m where m.household_id = transactions.household_id and m.user_id = (select auth.uid()))
);
create policy "users can update own transactions" on public.transactions
for update to authenticated using (
 user_id = (select auth.uid()) and
 exists (select 1 from public.household_members m where m.household_id = transactions.household_id and m.user_id = (select auth.uid()))
) with check (
 user_id = (select auth.uid()) and
 exists (select 1 from public.household_members m where m.household_id = transactions.household_id and m.user_id = (select auth.uid()))
);
create policy "users can delete own transactions" on public.transactions
for delete to authenticated using (
 user_id = (select auth.uid()) and
 exists (select 1 from public.household_members m where m.household_id = transactions.household_id and m.user_id = (select auth.uid()))
);
create policy "member read settings" on public.household_settings
for select to authenticated using (
 exists (select 1 from public.household_members m where m.household_id = household_settings.household_id and m.user_id = (select auth.uid()))
);
create policy "member update settings" on public.household_settings
for update to authenticated using (
 exists (select 1 from public.household_members m where m.household_id = household_settings.household_id and m.user_id = (select auth.uid()))
) with check (
 exists (select 1 from public.household_members m where m.household_id = household_settings.household_id and m.user_id = (select auth.uid()))
);

-- 招待機能はログインユーザーのみ利用可能にする。
create or replace function public.create_household()
returns uuid language plpgsql security definer set search_path = '' as $$
declare h uuid; u uuid := auth.uid();
begin
 if u is null then raise exception 'ログインしてください'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(u::text, 0));
 if exists (select 1 from public.household_members where user_id=u) then raise exception 'すでに家計簿に参加しています'; end if;
 insert into public.households(name) values ('ふたりの家計簿') returning id into h;
 insert into public.household_members(household_id,user_id,role) values(h,u,'owner');
 insert into public.household_settings(household_id) values(h);
 return h;
end; $$;

create or replace function public.join_household(p_invite_code uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare h uuid; u uuid := auth.uid(); n int;
begin
 if u is null then raise exception 'ログインしてください'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(u::text, 0));
 if exists (select 1 from public.household_members where user_id=u) then raise exception 'すでに家計簿に参加しています'; end if;
 select id into h from public.households where invite_code=p_invite_code for update;
 if h is null then raise exception '招待コードが正しくありません'; end if;
 select count(*) into n from public.household_members where household_id=h;
 if n >= 2 then raise exception 'この家計簿にはすでに2人参加しています'; end if;
 insert into public.household_members(household_id,user_id,role) values(h,u,'member');
 insert into public.household_settings(household_id) values(h) on conflict do nothing;
 return h;
end; $$;

revoke all on function public.create_household() from public, anon;
revoke all on function public.join_household(uuid) from public, anon;
grant execute on function public.create_household() to authenticated;
grant execute on function public.join_household(uuid) to authenticated;

-- テーブル操作は RLS で制限。メンバー・家計簿の直接書き換えは許可しない。
revoke all on public.households, public.household_members, public.transactions, public.household_settings from anon;
grant select on public.households, public.household_members, public.transactions, public.household_settings to authenticated;
grant insert, update, delete on public.transactions to authenticated;
grant update on public.household_settings to authenticated;

commit;
