import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./supabase-config.js";

const root = document.body;
const page = root.dataset.page;
let supabase;

const categoryLabels = {
    PLUMBING: "Plumbing",
    ELECTRICAL: "Electrical",
    HEATING_COOLING: "Heating / Cooling",
    APPLIANCES: "Appliances",
    MISCELLANEOUS: "Miscellaneous"
};

function showMessage(element, message, type = "error") {
    if (!element) return;
    element.textContent = message;
    element.className = `message ${type}`;
}

function formatDate(value) {
    if (!value) return "—";
    const date = new Date(value);
    return Number.isNaN(date.getTime())
        ? "—"
        : date.toLocaleDateString(undefined, {
            day: "numeric",
            month: "short",
            year: "numeric"
        });
}

function formatStatus(status) {
    return status.replaceAll("_", " ");
}

function statusClass(status) {
    return status.toLowerCase().replaceAll("_", "-");
}

function setText(id, value) {
    const element = document.getElementById(id);
    if (element) element.textContent = value || "—";
}

function addCell(row, value) {
    const cell = document.createElement("td");
    cell.textContent = value || "—";
    row.append(cell);
    return cell;
}

function addStatusCell(row, status) {
    const cell = document.createElement("td");
    const badge = document.createElement("span");
    badge.className = `status ${statusClass(status)}`;
    badge.textContent = formatStatus(status);
    cell.append(badge);
    row.append(cell);
}

function addButtonCell(row, label, issueId) {
    const cell = document.createElement("td");
    const button = document.createElement("a");
    button.className = "button button-small";
    button.href = `./issue-details.html?id=${encodeURIComponent(issueId)}`;
    button.textContent = label;
    cell.append(button);
    row.append(cell);
}

function dashboardPath(role) {
    return role === "AGENT"
        ? "./agent-dashboard.html"
        : "./tenant-dashboard.html";
}

async function getProfile(userId) {
    const { data, error } = await supabase
        .from("user")
        .select("id, name, role, property_address")
        .eq("id", userId)
        .single();
    return { profile: data, error };
}

async function routeSignedInUser(user) {
    const { profile, error } = await getProfile(user.id);
    if (error) {
        showMessage(document.getElementById("loginMessage"), `Unable to load your account: ${error.message}`);
        return;
    }
    if (profile.role !== "TENANT" && profile.role !== "AGENT") {
        showMessage(document.getElementById("loginMessage"), "Your account has an unsupported role. Contact your property manager.");
        return;
    }
    window.location.replace(dashboardPath(profile.role));
}

async function initializeLogin() {
    const loginMessage = document.getElementById("loginMessage");
    const form = document.getElementById("authForm");
    const modeButton = document.getElementById("toggleSignup");
    const submitButton = document.getElementById("loginBtn");
    const signupFields = document.getElementById("signupFields");
    let isSignup = false;

    const { data: { session }, error } = await supabase.auth.getSession();
    if (error) {
        showMessage(loginMessage, `Unable to check your session: ${error.message}`);
        return;
    }
    if (session) {
        await routeSignedInUser(session.user);
        return;
    }

    modeButton.addEventListener("click", () => {
        isSignup = !isSignup;
        signupFields.hidden = !isSignup;
        submitButton.textContent = isSignup ? "Create tenant account" : "Log in";
        modeButton.textContent = isSignup ? "Already have an account? Log in" : "New tenant? Create an account";
        document.getElementById("name").required = isSignup;
        document.getElementById("contact").required = isSignup;
        document.getElementById("propertyAddress").required = isSignup;
        showMessage(loginMessage, "");
    });

    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        submitButton.disabled = true;
        showMessage(loginMessage, "");

        const email = document.getElementById("email").value.trim();
        const password = document.getElementById("password").value;
        let user;

        if (isSignup) {
            const { data, error: signupError } = await supabase.auth.signUp({
                email,
                password,
                options: {
                    data: {
                        name: document.getElementById("name").value.trim(),
                        contact: document.getElementById("contact").value.trim(),
                        property_address: document.getElementById("propertyAddress").value.trim()
                    }
                }
            });
            if (signupError) {
                showMessage(loginMessage, signupError.message);
                submitButton.disabled = false;
                return;
            }
            user = data.user;
            if (!data.session) {
                showMessage(loginMessage, "Account created. Check your email to confirm your account, then log in.", "success");
                submitButton.disabled = false;
                return;
            }
        } else {
            const { data, error: loginError } = await supabase.auth.signInWithPassword({ email, password });
            if (loginError) {
                showMessage(loginMessage, loginError.message);
                submitButton.disabled = false;
                return;
            }
            user = data.user;
        }

        await routeSignedInUser(user);
        submitButton.disabled = false;
    });
}

async function requireUser(expectedRole) {
    const { data: { session }, error } = await supabase.auth.getSession();
    if (error) {
        showMessage(document.getElementById("pageMessage"), `Unable to check your session: ${error.message}`);
        return null;
    }
    if (!session) {
        window.location.replace("./login.html");
        return null;
    }

    const { profile, error: profileError } = await getProfile(session.user.id);
    if (profileError) {
        showMessage(document.getElementById("pageMessage"), `Unable to load your account: ${profileError.message}`);
        return null;
    }
    if (expectedRole && profile.role !== expectedRole) {
        if (profile.role !== "TENANT" && profile.role !== "AGENT") {
            showMessage(document.getElementById("pageMessage"), "Your account has an unsupported role. Contact your property manager.");
            return null;
        }
        const destination = dashboardPath(profile.role);
        if (window.location.pathname === destination) {
            showMessage(document.getElementById("pageMessage"), "Your account role does not match this page. Contact your property manager.");
            return null;
        }
        window.location.replace(destination);
        return null;
    }

    const nameElement = document.getElementById("userName");
    if (nameElement) nameElement.textContent = profile.name;
    const welcomeElement = document.getElementById("welcomeName");
    if (welcomeElement) welcomeElement.textContent = profile.name;
    document.querySelectorAll("[data-logout]").forEach((button) => {
        button.addEventListener("click", async () => {
            const { error: logoutError } = await supabase.auth.signOut();
            if (logoutError) {
                showMessage(document.getElementById("pageMessage"), `Unable to log out: ${logoutError.message}`);
                return;
            }
            window.location.replace("./login.html");
        });
    });
    return { user: session.user, profile };
}

async function initializeTenantDashboard(userProfile) {
    setText("propertyAddress", userProfile.profile.property_address);
    const tableBody = document.getElementById("issueRows");
    const { data: issues, error } = await supabase
        .from("tenant_issue_dashboard")
        .select("id, issue_title, issue_category, status, priority, date_logged, date_resolved")
        .order("date_logged", { ascending: false });

    if (error) {
        showMessage(document.getElementById("pageMessage"), `Unable to load maintenance requests: ${error.message}`);
        return;
    }
    if (!issues.length) {
        showMessage(document.getElementById("emptyState"), "You have not submitted any maintenance requests yet.", "info");
        return;
    }

    issues.forEach((issue) => {
        const row = document.createElement("tr");
        addCell(row, issue.issue_title);
        addCell(row, categoryLabels[issue.issue_category] || issue.issue_category);
        addCell(row, formatDate(issue.date_logged));
        addStatusCell(row, issue.status);
        addCell(row, issue.priority || "Not assigned");
        addButtonCell(row, "View details", issue.id);
        tableBody.append(row);
    });
}

async function initializeAgentDashboard() {
    const tableBody = document.getElementById("issueRows");
    const searchBox = document.getElementById("searchBox");
    const { data: issues, error } = await supabase
        .from("agent_issue_dashboard")
        .select("id, tenant_name, property_address, issue_title, issue_category, status, priority, date_logged")
        .order("date_logged", { ascending: false });

    if (error) {
        showMessage(document.getElementById("pageMessage"), `Unable to load assigned maintenance requests: ${error.message}`);
        return;
    }
    if (!issues.length) {
        showMessage(document.getElementById("emptyState"), "There are no unassigned or assigned requests in your queue.", "info");
        return;
    }

    issues.forEach((issue) => {
        const row = document.createElement("tr");
        row.dataset.search = [
            issue.issue_title,
            issue.tenant_name,
            issue.property_address,
            issue.issue_category,
            issue.status
        ].join(" ").toLowerCase();
        addCell(row, issue.issue_title);
        addCell(row, issue.tenant_name);
        addCell(row, issue.property_address);
        addStatusCell(row, issue.status);
        addCell(row, issue.priority || "Not assigned");
        addButtonCell(row, "Review", issue.id);
        tableBody.append(row);
    });

    searchBox.addEventListener("input", () => {
        const query = searchBox.value.trim().toLowerCase();
        tableBody.querySelectorAll("tr").forEach((row) => {
            row.hidden = !row.dataset.search.includes(query);
        });
    });
}

async function initializeNewIssue(userProfile) {
    document.getElementById("propertyAddress").value = userProfile.profile.property_address || "";
    const form = document.getElementById("issueForm");
    const submitButton = document.getElementById("submitIssueBtn");
    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        submitButton.disabled = true;
        showMessage(document.getElementById("issueMessage"), "");

        const issue = {
            issue_title: document.getElementById("issueTitle").value.trim(),
            issue_details: document.getElementById("issueDetails").value.trim(),
            issue_category: document.getElementById("category").value
        };
        const { data, error } = await supabase
            .from("issues")
            .insert(issue)
            .select("id")
            .single();

        if (error) {
            showMessage(document.getElementById("issueMessage"), `Unable to submit your request: ${error.message}`);
            submitButton.disabled = false;
            return;
        }
        window.location.replace(`./issue-details.html?id=${encodeURIComponent(data.id)}`);
    });
}

function renderIssue(issue, role, profile) {
    setText("issueTitle", issue.issue_title);
    setText("issueCategory", categoryLabels[issue.issue_category] || issue.issue_category);
    setText("issueDetails", issue.issue_details);
    setText("dateLogged", formatDate(issue.date_logged));
    setText("dateUpdated", formatDate(issue.last_updated));
    setText("dateResolved", formatDate(issue.date_resolved));
    setText("priority", issue.priority || "Not assigned");
    setText("tenantName", issue.tenant_name);
    setText("tenantContact", issue.tenant_contact);
    setText("propertyAddress", role === "AGENT" ? issue.property_address : profile.property_address);
    const tenantInfo = document.getElementById("tenantInfo");
    if (tenantInfo) tenantInfo.hidden = role !== "AGENT";

    const badge = document.getElementById("issueStatus");
    badge.className = `status ${statusClass(issue.status)}`;
    badge.textContent = formatStatus(issue.status);

    const backLink = document.getElementById("backLink");
    backLink.href = dashboardPath(role);

    const agentActions = document.getElementById("agentActions");
    if (role !== "AGENT" || issue.status === "RESOLVED") {
        agentActions.hidden = true;
        return;
    }
    agentActions.hidden = false;
    if (issue.status === "OPEN") {
        document.getElementById("startMaintenance").hidden = false;
        document.getElementById("resolveIssue").hidden = true;
        document.getElementById("priorityLabel").hidden = false;
        document.getElementById("prioritySelect").hidden = false;
        document.getElementById("prioritySelect").value = issue.priority || "";
    } else {
        document.getElementById("startMaintenance").hidden = true;
        document.getElementById("resolveIssue").hidden = false;
        document.getElementById("priorityLabel").hidden = true;
        document.getElementById("prioritySelect").hidden = true;
    }
}

async function initializeIssueDetails(userProfile) {
    const pathIssueId = window.location.pathname.match(/^\/issues\/([^/]+)\/?$/)?.[1];
    const issueId = new URLSearchParams(window.location.search).get("id") || pathIssueId;
    if (!issueId) {
        showMessage(document.getElementById("pageMessage"), "No maintenance request was selected.");
        return;
    }

    const isAgent = userProfile.profile.role === "AGENT";
    const { data: issue, error } = await supabase
        .from(isAgent ? "agent_issue_dashboard" : "issues")
        .select("*")
        .eq("id", issueId)
        .maybeSingle();

    if (error) {
        showMessage(document.getElementById("pageMessage"), `Unable to load this maintenance request: ${error.message}`);
        return;
    }
    if (!issue) {
        showMessage(document.getElementById("pageMessage"), "This request was not found or you do not have permission to view it.");
        return;
    }
    renderIssue(issue, userProfile.profile.role, userProfile.profile);

    if (!isAgent) return;
    const message = document.getElementById("actionMessage");
    const startButton = document.getElementById("startMaintenance");
    const resolveButton = document.getElementById("resolveIssue");

    startButton.addEventListener("click", async () => {
        const priority = document.getElementById("prioritySelect").value;
        if (!priority) {
            showMessage(message, "Choose a priority before starting maintenance.");
            return;
        }
        startButton.disabled = true;
        const { error: updateError } = await supabase
            .from("issues")
            .update({ agent_id: userProfile.user.id, priority, status: "IN_PROGRESS" })
            .eq("id", issueId)
            .select("id")
            .single();
        if (updateError) {
            showMessage(message, `Unable to start maintenance: ${updateError.message}`);
            startButton.disabled = false;
            return;
        }
        window.location.reload();
    });

    resolveButton.addEventListener("click", async () => {
        resolveButton.disabled = true;
        const { error: updateError } = await supabase
            .from("issues")
            .update({ status: "RESOLVED" })
            .eq("id", issueId)
            .select("id")
            .single();
        if (updateError) {
            showMessage(message, `Unable to resolve this request: ${updateError.message}`);
            resolveButton.disabled = false;
            return;
        }
        window.location.reload();
    });
}

async function initialize() {
    if (!page) {
        console.error("Missing data-page on the page body.");
        return;
    }
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
        showMessage(
            document.getElementById("loginMessage") || document.getElementById("pageMessage"),
            "Supabase is not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY in frontend/supabase-config.js."
        );
        return;
    }
    try {
        const projectUrl = new URL(SUPABASE_URL);
        if (projectUrl.protocol !== "https:" && projectUrl.protocol !== "http:") {
            showMessage(document.getElementById("loginMessage") || document.getElementById("pageMessage"), "SUPABASE_URL must use HTTP or HTTPS.");
            return;
        }
    } catch {
        showMessage(document.getElementById("loginMessage") || document.getElementById("pageMessage"), "SUPABASE_URL is not a valid URL.");
        return;
    }
    supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    if (page === "login") {
        await initializeLogin();
        return;
    }

    const expectedRole = page === "issue-details"
        ? null
        : page === "agent-dashboard" || page === "agent-issue" ? "AGENT" : "TENANT";
    const userProfile = await requireUser(expectedRole);
    if (!userProfile) return;

    if (page === "tenant-dashboard") await initializeTenantDashboard(userProfile);
    if (page === "agent-dashboard") await initializeAgentDashboard();
    if (page === "new-issue") await initializeNewIssue(userProfile);
    if (page === "issue-details" || page === "agent-issue" || page === "tenant-issue") {
        await initializeIssueDetails(userProfile);
    }
}

initialize();
