package com.intertec.autoops.auth.repo;

import com.intertec.autoops.auth.domain.Tenant;
import org.springframework.data.jpa.repository.JpaRepository;

public interface TenantRepository extends JpaRepository<Tenant, String> {

    /** One organization per corporate email domain (globally unique claim). */
    boolean existsByEmailDomain(String emailDomain);
}
