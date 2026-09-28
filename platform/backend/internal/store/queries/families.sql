-- name: CreateFamily :exec
insert into families(id, name, owner_id, created_at)
values (sqlc.arg(id), sqlc.arg(name), sqlc.arg(owner_id), sqlc.arg(created_at));

-- name: FamilyByID :one
select id, name, owner_id from families where id=sqlc.arg(id);

-- name: RenameFamily :execrows
update families set name=sqlc.arg(name)
where id=sqlc.arg(id) and owner_id=sqlc.arg(owner_id);

-- name: ActiveFamilyMembers :many
select fm.user_id, u.display_name, fm.role, fm.joined_at
from family_members as fm
join users as u on u.id=fm.user_id
where fm.family_id=sqlc.arg(family_id) and fm.removed_at is null and u.deleted_at is null
order by case fm.role when 'owner' then 0 else 1 end, fm.joined_at, fm.user_id;

-- name: FamilyMemberRole :one
select role from family_members
where family_id=sqlc.arg(family_id) and user_id=sqlc.arg(user_id) and removed_at is null;

-- name: RemoveCaregiver :execrows
update family_members set removed_at=sqlc.arg(removed_at)
where family_id=sqlc.arg(family_id) and user_id=sqlc.arg(user_id)
  and role='caregiver' and removed_at is null
  and exists (select 1 from families where id=sqlc.arg(family_id)
    and (owner_id=sqlc.arg(actor_id) or sqlc.arg(actor_id)=sqlc.arg(user_id)));

-- name: ActiveFamilyMemberCount :one
select count(*) from family_members
where family_id=sqlc.arg(family_id) and removed_at is null;

-- name: OwnedFamilyIDs :many
select id from families
where owner_id=sqlc.arg(owner_id)
order by created_at, id;

-- name: FamilyOwnershipSuccessor :one
select user_id from family_members
where family_id=sqlc.arg(family_id)
  and user_id<>sqlc.arg(owner_id)
  and removed_at is null
order by joined_at, user_id
limit 1;

-- name: TransferFamilyOwnership :execrows
update families set owner_id=sqlc.arg(successor_id)
where id=sqlc.arg(id) and owner_id=sqlc.arg(owner_id);

-- name: PromoteFamilyOwner :execrows
update family_members set role='owner'
where family_id=sqlc.arg(family_id)
  and user_id=sqlc.arg(user_id)
  and removed_at is null;

-- name: DemoteFamilyOwner :execrows
update family_members set role='caregiver'
where family_id=sqlc.arg(family_id) and user_id=sqlc.arg(user_id)
  and role='owner' and removed_at is null;

-- name: DeleteFamilyOwnedBy :execrows
delete from families
where id=sqlc.arg(id) and owner_id=sqlc.arg(owner_id);

-- name: DeleteSoleOwnerFamily :execrows
delete from families
where id=sqlc.arg(id) and owner_id=sqlc.arg(owner_id)
  and (select count(*) from family_members where family_id=sqlc.arg(id) and removed_at is null)=1;

-- name: FamiliesForUser :many
select f.id, f.name, fm.role
from families as f
inner join family_members as fm on f.id=fm.family_id
where fm.user_id=sqlc.arg(user_id) and fm.removed_at is null
order by fm.joined_at, f.id;

-- name: AddOwner :exec
insert into family_members(family_id, user_id, role, joined_at)
values (sqlc.arg(family_id), sqlc.arg(user_id), 'owner', sqlc.arg(joined_at));

-- name: AddCaregiver :exec
insert into family_members(family_id, user_id, role, joined_at)
values (sqlc.arg(family_id), sqlc.arg(user_id), 'caregiver', sqlc.arg(joined_at))
on conflict(family_id, user_id) do update set
  removed_at=null,
  joined_at=excluded.joined_at;

-- name: IsFamilyMember :one
select exists(
  select 1 from family_members
  where family_id=sqlc.arg(family_id)
    and user_id=sqlc.arg(user_id)
    and removed_at is null
);

-- name: HasFamilyRole :one
select exists(
  select 1 from family_members
  where family_id=sqlc.arg(family_id)
    and user_id=sqlc.arg(user_id)
    and role=sqlc.arg(role)
    and removed_at is null
);

-- name: CreateInvite :exec
insert into invites(id, family_id, token_hash, created_by, expires_at, created_at)
values (sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(token_hash), sqlc.arg(created_by), sqlc.arg(expires_at), sqlc.arg(created_at));

-- name: PendingFamilyInvites :many
select id, expires_at, created_at from invites
where family_id=sqlc.arg(family_id) and claimed_at is null and expires_at>sqlc.arg(now)
order by created_at desc, id;

-- name: RevokePendingInvite :execrows
delete from invites as i where i.id=sqlc.arg(id) and i.family_id=sqlc.arg(family_id) and i.claimed_at is null
  and exists (select 1 from families as f where f.id=sqlc.arg(family_id) and f.owner_id=sqlc.arg(owner_id));

-- name: InviteByTokenHash :one
select id, family_id, expires_at, claimed_by, claimed_at
from invites
where token_hash=sqlc.arg(token_hash);

-- name: ClaimInvite :execrows
update invites set claimed_by=sqlc.arg(claimed_by), claimed_at=sqlc.arg(claimed_at)
where id=sqlc.arg(id) and claimed_at is null;
