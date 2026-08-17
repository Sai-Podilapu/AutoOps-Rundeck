package com.intertec.autoops.auth.repo;

import com.intertec.autoops.auth.domain.TenantIdpConfig;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;

public interface TenantIdpConfigRepository extends JpaRepository<TenantIdpConfig, String> {

    /** Login-page domain routing: which tenant owns this email domain? */
    @Query("select c from TenantIdpConfig c join c.emailDomains d where d = :domain")
    Optional<TenantIdpConfig> findByDomain(@Param("domain") String domain);
}
