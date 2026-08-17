package com.intertec.autoops.core.domain;

/**
 * What a {@link CloudAccountClaim} pins down.
 *
 * <p>ACCOUNT is the stronger rule — it survives key rotation and catches the
 * same account presented with a different key pair. CREDENTIAL is the earlier
 * one — it fires the moment the material is submitted, before any provider
 * round-trip, which is what catches a plain credential leak.
 */
public enum CloudAccountClaimKind {

    /** The cloud account the credentials point at. */
    ACCOUNT,

    /** The credential material that authenticates to it. */
    CREDENTIAL
}