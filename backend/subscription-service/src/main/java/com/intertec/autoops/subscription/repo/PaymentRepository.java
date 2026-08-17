package com.intertec.autoops.subscription.repo;

import com.intertec.autoops.subscription.domain.Payment;
import com.intertec.autoops.subscription.domain.PaymentStatus;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.Optional;

public interface PaymentRepository extends JpaRepository<Payment, Long> {

    List<Payment> findByTenantIdOrderByCreatedAtDesc(String tenantId);

    /** Provider view: newest payments across every tenant. */
    List<Payment> findTop200ByOrderByCreatedAtDesc();

    /** The retry target: the most recent failed charge for the tenant. */
    Optional<Payment> findTopByTenantIdAndStatusOrderByCreatedAtDesc(String tenantId,
                                                                     PaymentStatus status);
}
