package com.intertec.autoops.auth.web.dto;

import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserRole;
import com.intertec.autoops.auth.domain.UserStatus;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The platform's FIXED role catalog with live member counts and the
 * permission matrix as actually enforced across the services (each grant
 * mirrors a real backend check — this is documentation of enforcement,
 * not configuration). PROVIDER only appears when such an account exists
 * in the roster; custom roles are not supported.
 */
public record RoleCatalogResponse(List<PermissionDef> permissions, List<RoleInfo> roles) {

    public record PermissionDef(String key, String label) {
    }

    public record RoleInfo(String code, String name, String description, long members,
                           Map<String, Boolean> grants) {
    }

    private static final List<PermissionDef> PERMISSIONS = List.of(
            new PermissionDef("manageMembers", "Invite & manage members"),
            new PermissionDef("manageBilling", "Manage billing & plan"),
            new PermissionDef("editAutomations", "Create & edit projects, jobs, workflows"),
            new PermissionDef("runAutomations", "Run jobs & workflows"),
            new PermissionDef("approveRuns", "Approve gated runs"),
            new PermissionDef("manageIntegrations", "Manage cloud integrations"),
            new PermissionDef("manageScm", "Configure git sync"),
            new PermissionDef("manageApprovalRules", "Set approval rules"),
            new PermissionDef("manageGovernance", "Set governance policies"));

    public static RoleCatalogResponse forTenant(List<User> roster) {
        List<RoleInfo> roles = new ArrayList<>();
        roles.add(new RoleInfo("ADMIN", "Admin",
                "Full control: members, billing, approvals, governance and all automation.",
                count(roster, UserRole.ADMIN), adminGrants()));
        roles.add(new RoleInfo("CLIENT", "Operator",
                "Builds and runs automation; risky or complex runs queue for admin approval.",
                count(roster, UserRole.CLIENT), operatorGrants()));
        roles.add(new RoleInfo("VIEWER", "Viewer",
                "Read-only: sees projects, runs and reports but cannot change or run anything.",
                count(roster, UserRole.VIEWER), viewerGrants()));
        long providers = count(roster, UserRole.PROVIDER);
        if (providers > 0) {
            roles.add(new RoleInfo("PROVIDER", "Provider",
                    "Platform operator account: billing management plus standard automation access.",
                    providers, providerGrants()));
        }
        return new RoleCatalogResponse(PERMISSIONS, roles);
    }

    private static long count(List<User> roster, UserRole role) {
        // PENDING members hold their role from the moment they are invited.
        return roster.stream()
                .filter(u -> u.getRole() == role && u.getStatus() != UserStatus.DISABLED)
                .count();
    }

    // Each grant mirrors a real enforcement point:
    //  - manageMembers: auth-service requireAdmin on onboard/offboard/role change
    //  - manageBilling: subscription-service ADMIN|PROVIDER on subscribe/cancel/retry
    //  - approveRuns/manageScm/manageApprovalRules/manageGovernance: core-service
    //    approval_admin_only / scm_admin_only / governance_admin_only checks
    //  - edit/run/integrations: open to every member (subscription-gated, not role-gated)

    private static Map<String, Boolean> adminGrants() {
        return grants(true, true, true, true, true, true, true, true, true);
    }

    private static Map<String, Boolean> operatorGrants() {
        return grants(false, false, true, true, false, true, false, false, false);
    }

    // Viewers hold no grant at all: core-service refuses every mutating
    // method for the VIEWER role claim before it reaches a controller.
    private static Map<String, Boolean> viewerGrants() {
        return grants(false, false, false, false, false, false, false, false, false);
    }

    private static Map<String, Boolean> providerGrants() {
        return grants(false, true, true, true, false, true, false, false, false);
    }

    private static Map<String, Boolean> grants(boolean... values) {
        Map<String, Boolean> map = new LinkedHashMap<>();
        for (int i = 0; i < PERMISSIONS.size(); i++) {
            map.put(PERMISSIONS.get(i).key(), values[i]);
        }
        return map;
    }
}