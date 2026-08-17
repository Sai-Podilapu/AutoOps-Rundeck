package com.intertec.autoops.voice.elevenlabs;

import org.springframework.http.HttpStatus;

/**
 * An upstream failure, already translated into what the visitor should be told.
 * The message is safe to serialise: it never carries the API key or the raw
 * ElevenLabs body, both of which can contain account detail.
 */
public class ElevenLabsException extends RuntimeException {

    private final HttpStatus status;

    public ElevenLabsException(HttpStatus status, String message) {
        super(message);
        this.status = status;
    }

    public ElevenLabsException(HttpStatus status, String message, Throwable cause) {
        super(message, cause);
        this.status = status;
    }

    public HttpStatus getStatus() {
        return status;
    }
}
