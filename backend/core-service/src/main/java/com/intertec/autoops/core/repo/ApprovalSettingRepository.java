package com.intertec.autoops.core.repo;

import com.intertec.autoops.core.domain.ApprovalSetting;
import org.springframework.data.jpa.repository.JpaRepository;

public interface ApprovalSettingRepository extends JpaRepository<ApprovalSetting, String> {
}