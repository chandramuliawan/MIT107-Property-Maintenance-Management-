/* ============================================================================
   PROPERTY MAINTENANCE MANAGEMENT SYSTEM
   Supabase / PostgreSQL database setup

   File: property_maintenance_supabase_setup.sql

   PURPOSE
   -------
   This script creates the database structure and security configuration used
   by the property maintenance prototype:

     1. Custom data types (enums)
     2. Application user table: public."user"
     3. Maintenance issue table: public.issues
     4. Automatic application-user creation after Supabase Auth signup
     5. Automatic maintenance-issue date management
     6. Helper functions used by Row Level Security (RLS)
     7. RLS policies for tenants and agents
     8. Table, view, and function permissions
     9. Dashboard views for tenants and agents

   HOW TO RUN
   ----------
   Open your Supabase project -> SQL Editor -> New query. Copy the contents of
   this file into the editor and run the query as the project database admin.

   IMPORTANT NOTES
   ---------------
   - This is a SCHEMA / CONFIGURATION backup. It does not back up existing rows
     in your tables, Auth accounts, Storage files, or other project data.
   - This script is intended for the property-maintenance schema described
     above. It does not delete table rows.
   - If the two project tables already exist, CREATE TABLE IF NOT EXISTS will
     leave their existing columns and constraints unchanged. Review the live
     schema before using this script to repair an existing, modified database.
   - To avoid accidentally leaving permissive old policies in place, this
     script removes ALL existing RLS policies on public."user" and
     public.issues before creating the policies below. It does not remove rows.
   - The table name "user" is a PostgreSQL keyword, so it is quoted everywhere
     as public."user".
   - Supabase Auth stores credentials in auth.users. The public."user" table
     stores application details and is linked to auth.users by the same UUID.
   - Never put a Supabase service_role / secret key, user password, or real
     access token in this file or commit those credentials to GitHub.

   APPLICATION MODEL
   -----------------
   One application-user table represents both TENANT and AGENT accounts.
   The role column distinguishes the two. The issues table stores maintenance
   requests and links each request to its tenant and (optionally) its agent.
   ============================================================================ */


/* ============================================================================
   SECTION 1 - CUSTOM ENUM TYPES
   ---------------------------------------------------------------------------
   Enum types restrict columns to known values. The duplicate_object handling
   makes this section safe to run when these types already exist. Existing enum
   definitions are not modified by this block.
   ============================================================================ */

DO $$
BEGIN
    CREATE TYPE public.user_role AS ENUM ('TENANT', 'AGENT');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE public.issue_status AS ENUM ('OPEN', 'IN_PROGRESS', 'RESOLVED');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE public.issue_priority AS ENUM ('LOW', 'MED', 'URGENT');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE public.issue_category AS ENUM (
        'PLUMBING',
        'ELECTRICAL',
        'HEATING_COOLING',
        'APPLIANCES',
        'MISCELLANEOUS'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

-- Signed-in users need permission to use the enum types through the API.
GRANT USAGE ON TYPE public.user_role TO authenticated;
GRANT USAGE ON TYPE public.issue_status TO authenticated;
GRANT USAGE ON TYPE public.issue_priority TO authenticated;
GRANT USAGE ON TYPE public.issue_category TO authenticated;


/* ============================================================================
   SECTION 2 - APPLICATION USER TABLE
   ---------------------------------------------------------------------------
   Supabase Auth creates the login account in auth.users. This separate table
   stores the information used by the application (name, role, contact details,
   property address, and optional employee ID).

   The primary key is also a foreign key to auth.users.id. This ensures that
   every application-user record belongs to a Supabase Auth account.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS public."user" (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    role public.user_role NOT NULL DEFAULT 'TENANT',
    contact TEXT,
    property_address TEXT,
    employee_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public."user" IS
    'Application profile for a Supabase Auth account. TENANT and AGENT roles are stored in this table.';
COMMENT ON COLUMN public."user".id IS
    'Same UUID as auth.users.id; also the primary key of the application user.';
COMMENT ON COLUMN public."user".role IS
    'Application role. New accounts are created as TENANT by the signup trigger.';
COMMENT ON COLUMN public."user".employee_id IS
    'Optional employee identifier used for AGENT accounts.';

CREATE INDEX IF NOT EXISTS idx_user_role
    ON public."user" (role);


/* ============================================================================
   SECTION 3 - MAINTENANCE ISSUES TABLE
   ---------------------------------------------------------------------------
   Each row represents a maintenance issue submitted by a tenant.

   tenant_id defaults to auth.uid(), which is the UUID of the signed-in user.
   agent_id stays NULL until an agent claims the issue.

   The CHECK constraint ensures that date_resolved is present only when the
   issue status is RESOLVED. A trigger in Section 5 maintains this date.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS public.issues (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id UUID NOT NULL DEFAULT auth.uid()
        REFERENCES public."user"(id) ON DELETE RESTRICT,

    agent_id UUID
        REFERENCES public."user"(id) ON DELETE SET NULL,

    issue_title TEXT NOT NULL,
    issue_details TEXT NOT NULL,
    issue_category public.issue_category NOT NULL,

    date_logged TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    date_resolved TIMESTAMPTZ,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    status public.issue_status NOT NULL DEFAULT 'OPEN',
    priority public.issue_priority,

    CONSTRAINT issues_resolution_date_check CHECK (
        (status = 'RESOLVED' AND date_resolved IS NOT NULL)
        OR
        (status <> 'RESOLVED' AND date_resolved IS NULL)
    )
);

COMMENT ON TABLE public.issues IS
    'Maintenance requests submitted by tenants and managed by agents.';
COMMENT ON COLUMN public.issues.tenant_id IS
    'Application-user UUID of the tenant who submitted the issue.';
COMMENT ON COLUMN public.issues.agent_id IS
    'Application-user UUID of the agent handling the issue; NULL means unassigned.';
COMMENT ON COLUMN public.issues.date_logged IS
    'Date and time when the issue was created.';
COMMENT ON COLUMN public.issues.date_resolved IS
    'Date and time when the issue was moved to RESOLVED. Managed by a trigger.';
COMMENT ON COLUMN public.issues.last_updated IS
    'Date and time of the most recent update. Managed by a trigger.';
COMMENT ON COLUMN public.issues.priority IS
    'Priority assigned by an agent. NULL until an agent sets it.';

-- Indexes help common lookups used by tenant and agent dashboards.
CREATE INDEX IF NOT EXISTS idx_issues_tenant_id
    ON public.issues (tenant_id);

CREATE INDEX IF NOT EXISTS idx_issues_agent_id
    ON public.issues (agent_id);

CREATE INDEX IF NOT EXISTS idx_issues_status
    ON public.issues (status);

CREATE INDEX IF NOT EXISTS idx_issues_category
    ON public.issues (issue_category);


/* ============================================================================
   SECTION 4 - AUTOMATIC USER PROFILE CREATION
   ---------------------------------------------------------------------------
   When a new account is inserted into auth.users, this trigger function creates
   its matching row in public."user".

   Signup metadata can include:
     name
     contact
     property_address

   The application role is deliberately NOT taken from signup metadata.
   Every self-registered account starts as TENANT. An administrator can promote
   a trusted account to AGENT using the SQL Editor (see the notes after this
   script).
   ============================================================================ */

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public."user" (
        id,
        name,
        email,
        role,
        contact,
        property_address
    )
    VALUES (
        NEW.id,
        COALESCE(
            NULLIF(NEW.raw_user_meta_data ->> 'name', ''),
            split_part(COALESCE(NEW.email, 'new-user'), '@', 1)
        ),
        COALESCE(NEW.email, ''),
        'TENANT'::public.user_role,
        NEW.raw_user_meta_data ->> 'contact',
        NEW.raw_user_meta_data ->> 'property_address'
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

-- Recreate the trigger so the function runs after each Auth account is created.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_user();

-- This function is intended to run as a trigger, not to be called directly by API users.
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;


/* ============================================================================
   SECTION 5 - ISSUE DATE-MANAGEMENT TRIGGER
   ---------------------------------------------------------------------------
   Before an issue is updated:
     - last_updated is refreshed.
     - date_resolved is set when status first becomes RESOLVED.
     - date_resolved is cleared if the status changes back from RESOLVED.

   This keeps the date fields consistent when agents update issues through the
   Supabase API, rather than relying on the frontend to calculate timestamps.
   ============================================================================ */

CREATE OR REPLACE FUNCTION public.update_issue_dates()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.last_updated := NOW();

    IF NEW.status = 'RESOLVED'::public.issue_status
       AND OLD.status <> 'RESOLVED'::public.issue_status THEN
        NEW.date_resolved := NOW();
    ELSIF NEW.status <> 'RESOLVED'::public.issue_status THEN
        NEW.date_resolved := NULL;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS update_issue_dates_trigger ON public.issues;

CREATE TRIGGER update_issue_dates_trigger
BEFORE UPDATE ON public.issues
FOR EACH ROW
EXECUTE FUNCTION public.update_issue_dates();

REVOKE EXECUTE ON FUNCTION public.update_issue_dates() FROM PUBLIC, anon, authenticated;


/* ============================================================================
   SECTION 6 - PRIVATE RLS HELPER FUNCTIONS
   ---------------------------------------------------------------------------
   These functions check the role of the currently authenticated account.

   They are SECURITY DEFINER functions so they can read the application user
   table without causing recursive evaluation of the user-table RLS policies.
   Their search_path is empty and all objects are schema-qualified for safety.

   They are placed in a private schema so they are not intended as public REST
   API endpoints. Authenticated users are granted only the permissions needed
   for these functions to be called from RLS policies.
   ============================================================================ */

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE OR REPLACE FUNCTION private.is_agent()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public."user" AS app_user
        WHERE app_user.id = (SELECT auth.uid())
          AND app_user.role = 'AGENT'::public.user_role
    );
$$;

CREATE OR REPLACE FUNCTION private.is_tenant()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public."user" AS app_user
        WHERE app_user.id = (SELECT auth.uid())
          AND app_user.role = 'TENANT'::public.user_role
    );
$$;

REVOKE ALL ON FUNCTION private.is_agent() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.is_tenant() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_agent() TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_tenant() TO authenticated;


/* ============================================================================
   SECTION 7 - ENABLE ROW LEVEL SECURITY (RLS)
   ---------------------------------------------------------------------------
   RLS makes the database enforce which records each signed-in user can access.
   Hiding buttons in the frontend is not a security control; these database
   policies are the actual access restrictions.
   ============================================================================ */

ALTER TABLE public."user" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.issues ENABLE ROW LEVEL SECURITY;

-- Remove every existing policy on these two tables before installing this
-- policy set. This prevents an older permissive policy from being OR-ed with
-- the new policies. This affects policies only, not table data.
DO $$
DECLARE
    policy_row RECORD;
BEGIN
    FOR policy_row IN
        SELECT schemaname, tablename, policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('user', 'issues')
    LOOP
        EXECUTE format(
            'DROP POLICY IF EXISTS %I ON %I.%I',
            policy_row.policyname,
            policy_row.schemaname,
            policy_row.tablename
        );
    END LOOP;
END
$$;


/* ---------------------------------------------------------------------------
   7A - USER TABLE POLICY

   A tenant can read only their own application-user record.
   An agent can read all application-user records, which is needed to view
   tenant details and names in the agent dashboard.
   No frontend role is granted permission to change roles or user details.
   --------------------------------------------------------------------------- */

CREATE POLICY user_select_own_or_agent
ON public."user"
FOR SELECT
TO authenticated
USING (
    id = (SELECT auth.uid())
    OR (SELECT private.is_agent())
);


/* ---------------------------------------------------------------------------
   7B - ISSUE SELECT POLICY

   Tenants can read issues they submitted.
   Agents can read issues that are unassigned or assigned to themselves.
   An agent cannot use this policy to read another agent's assigned issues.
   --------------------------------------------------------------------------- */

CREATE POLICY issues_select_tenant_or_agent
ON public.issues
FOR SELECT
TO authenticated
USING (
    tenant_id = (SELECT auth.uid())
    OR (
        (SELECT private.is_agent())
        AND (agent_id IS NULL OR agent_id = (SELECT auth.uid()))
    )
);


/* ---------------------------------------------------------------------------
   7C - ISSUE INSERT POLICY

   Only a signed-in TENANT can submit an issue for themselves.
   The tenant cannot assign an agent, set priority, or create a resolved issue.
   Defaults populate tenant_id, status, and timestamps.
   --------------------------------------------------------------------------- */

CREATE POLICY issues_insert_tenant_only
ON public.issues
FOR INSERT
TO authenticated
WITH CHECK (
    (SELECT private.is_tenant())
    AND tenant_id = (SELECT auth.uid())
    AND agent_id IS NULL
    AND status = 'OPEN'::public.issue_status
    AND priority IS NULL
    AND date_resolved IS NULL
);


/* ---------------------------------------------------------------------------
   7D - ISSUE UPDATE POLICY

   Only agents can update issues.
   They can update an unassigned issue to claim it, or continue updating an
   issue already assigned to themselves. After the update, agent_id must be
   their own user UUID. Column-level grants in Section 8 limit which fields
   they can change.
   --------------------------------------------------------------------------- */

CREATE POLICY issues_update_agent_only
ON public.issues
FOR UPDATE
TO authenticated
USING (
    (SELECT private.is_agent())
    AND (agent_id IS NULL OR agent_id = (SELECT auth.uid()))
)
WITH CHECK (
    (SELECT private.is_agent())
    AND agent_id = (SELECT auth.uid())
);


/* ============================================================================
   SECTION 8 - TABLE AND FUNCTION PERMISSIONS
   ---------------------------------------------------------------------------
   RLS policies decide which rows a user can access. SQL grants decide which
   operations and columns a role can use. Both layers are required.

   Tenants receive permission to read their allowed user/issues rows and to
   insert only the three issue-description fields. Agents receive permission
   to update only the assignment, priority, and status fields.
   ============================================================================ */

GRANT USAGE ON SCHEMA public TO authenticated;

-- Remove broad table permissions from browser-facing roles before granting
-- only the operations required by this application.
REVOKE ALL ON TABLE public."user" FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.issues FROM PUBLIC, anon, authenticated;

-- Users can read rows allowed by RLS, but cannot modify their role or profile
-- from the browser through this table.
GRANT SELECT ON TABLE public."user" TO authenticated;

-- Both roles can select issue rows allowed by RLS.
GRANT SELECT ON TABLE public.issues TO authenticated;

-- Tenants can insert only issue content. Database defaults fill the other fields.
GRANT INSERT (issue_title, issue_details, issue_category)
ON TABLE public.issues TO authenticated;

-- Agents can change only these fields. RLS still decides which issue rows
-- they are allowed to update.
GRANT UPDATE (agent_id, priority, status)
ON TABLE public.issues TO authenticated;


/* ============================================================================
   SECTION 9 - DASHBOARD VIEWS
   ---------------------------------------------------------------------------
   Views provide convenient read models for the frontend:
     - tenant_issue_dashboard: issue information for a tenant's own requests.
     - agent_issue_dashboard: issue and tenant information for the agent queue.

   security_invoker = true is important: the views use the querying user's
   permissions and the underlying table RLS policies, instead of bypassing RLS.
   ============================================================================ */

-- Drop the old definitions first so this script can also replace a view
-- whose selected columns changed during development. These views contain no
-- stored data; dropping them does not delete issue or user records.
DROP VIEW IF EXISTS public.agent_issue_dashboard;
DROP VIEW IF EXISTS public.tenant_issue_dashboard;

CREATE VIEW public.tenant_issue_dashboard
WITH (security_invoker = true)
AS
SELECT
    id,
    tenant_id,
    issue_title,
    issue_category,
    status,
    priority,
    date_logged,
    date_resolved,
    last_updated
FROM public.issues;

COMMENT ON VIEW public.tenant_issue_dashboard IS
    'Tenant dashboard read model. Underlying issues RLS restricts rows to the signed-in tenant.';

CREATE VIEW public.agent_issue_dashboard
WITH (security_invoker = true)
AS
SELECT
    issue.id,
    issue.tenant_id,
    tenant.name AS tenant_name,
    tenant.email AS tenant_email,
    tenant.contact AS tenant_contact,
    tenant.property_address,
    issue.issue_title,
    issue.issue_details,
    issue.issue_category,
    issue.status,
    issue.priority,
    issue.date_logged,
    issue.date_resolved,
    issue.last_updated,
    issue.agent_id,
    agent.name AS agent_name
FROM public.issues AS issue
INNER JOIN public."user" AS tenant
    ON tenant.id = issue.tenant_id
LEFT JOIN public."user" AS agent
    ON agent.id = issue.agent_id;

COMMENT ON VIEW public.agent_issue_dashboard IS
    'Agent dashboard read model. RLS limits agents to unassigned issues and issues assigned to themselves.';

-- Do not expose these views to anonymous users. Authenticated access is still
-- filtered by the underlying RLS policies because security_invoker is enabled.
REVOKE ALL ON TABLE public.tenant_issue_dashboard FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.agent_issue_dashboard FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.tenant_issue_dashboard TO authenticated;
GRANT SELECT ON TABLE public.agent_issue_dashboard TO authenticated;


/* ============================================================================
   SECTION 10 - END OF SETUP
   ---------------------------------------------------------------------------
   The core schema and security configuration are now in place.

   To create an AGENT account:
     1. Create the account through Supabase Authentication -> Users.
     2. Find its email address and run the following as a database admin,
        replacing the example email and employee ID:

        UPDATE public."user"
        SET role = 'AGENT', employee_id = 'EMP001'
        WHERE email = 'agent1@example.com';

   To create a TENANT account, create a normal Supabase Auth user. The trigger
   creates the application record with role TENANT automatically.

   Example API endpoints (use the user's access token, not a service key):
     POST  /auth/v1/signup
     POST  /auth/v1/token?grant_type=password
     POST  /rest/v1/issues
     GET   /rest/v1/tenant_issue_dashboard?select=*
     GET   /rest/v1/agent_issue_dashboard?select=*
     PATCH /rest/v1/issues?id=eq.<issue-uuid>

   NOTE: Supabase's Data API must have the public schema enabled/exposed for
   these REST endpoints to be available. Keep secret/service_role keys on a
   trusted server only; never place them in browser JavaScript or GitHub.
   ============================================================================ */
