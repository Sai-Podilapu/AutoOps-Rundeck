package com.intertec.autoops.auth.web.dto;

import com.intertec.autoops.auth.domain.User;
import com.intertec.autoops.auth.domain.UserRole;
import com.intertec.autoops.auth.domain.UserStatus;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The role catalog documents real enforcement: counts come from the live
 * roster (DISABLED excluded), PROVIDER appears only when present, and the
 * grants mirror the admin-only checks across the services.
 */
class RoleCatalogResponseTest {

    private static User user(UserRole role, UserStatus status) {
        User user = new User();
        user.setRole(role);
        user.setStatus(status);
        return user;
    }

    @Test
    void countsLiveMembersAndHidesEmptyProviderRole() {
        RoleCatalogResponse catalog = RoleCatalogResponse.forTenant(List.of(
                user(UserRole.ADMIN, UserStatus.ACTIVE),
                user(UserRole.CLIENT, UserStatus.ACTIVE),
                user(UserRole.CLIENT, UserStatus.PENDING),
                user(UserRole.CLIENT, UserStatus.DISABLED)));

        assertEquals(2, catalog.roles().size(), "no PROVIDER row without provider accounts");
        assertEquals(1, catalog.roles().get(0).members());
        assertEquals(2, catalog.roles().get(1).members(), "PENDING counts, DISABLED does not");
        assertEquals(9, catalog.permissions().size());
    }

    @Test
    void grantsMirrorTheEnforcedChecks() {
        RoleCatalogResponse catalog = RoleCatalogResponse.forTenant(List.of(
                user(UserRole.PROVIDER, UserStatus.ACTIVE)));

        RoleCatalogResponse.RoleInfo admin = catalog.roles().get(0);
        RoleCatalogResponse.RoleInfo operator = catalog.roles().get(1);
        RoleCatalogResponse.RoleInfo provider = catalog.roles().get(2);

        assertTrue(admin.grants().values().stream().allMatch(Boolean::booleanValue));
        assertFalse(operator.grants().get("manageMembers"));
        assertFalse(operator.grants().get("approveRuns"));
        assertTrue(operator.grants().get("editAutomations"));
        assertTrue(operator.grants().get("runAutomations"));
        assertTrue(provider.grants().get("manageBilling"));
        assertFalse(provider.grants().get("manageMembers"));
        assertEquals(1, provider.members());
    }
}