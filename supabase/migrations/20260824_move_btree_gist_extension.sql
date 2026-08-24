-- Move btree_gist out of the public schema (Supabase security lint: extension_in_public)
create schema if not exists extensions;
alter extension btree_gist set schema extensions;
