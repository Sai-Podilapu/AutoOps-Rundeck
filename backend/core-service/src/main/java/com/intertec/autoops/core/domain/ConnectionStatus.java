package com.intertec.autoops.core.domain;

/** DISCONNECTED connections keep their row (audit/history) but count freed. */
public enum ConnectionStatus {
    CONNECTED,
    DISCONNECTED
}
