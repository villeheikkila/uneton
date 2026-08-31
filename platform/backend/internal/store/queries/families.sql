-- name: CreateFamily :exec
insert into families(id, name, owner_id, created_at)
values (sqlc.arg(id), sqlc.arg(name), sqlc.arg(owner_id), sqlc.arg(created_at));

-- name: FamilyByID :one
select id, name, owner_id from families where id=sqlc.arg(id);

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

-- name: DeleteFamilyOwnedBy :execrows
delete from families
where id=sqlc.arg(id) and owner_id=sqlc.arg(owner_id);

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

-- name: InviteByTokenHash :one
select id, family_id, expires_at, claimed_by, claimed_at
from invites
where token_hash=sqlc.arg(token_hash);

-- name: ClaimInvite :execrows
update invites set claimed_by=sqlc.arg(claimed_by), claimed_at=sqlc.arg(claimed_at)
where id=sqlc.arg(id) and claimed_at is null;
