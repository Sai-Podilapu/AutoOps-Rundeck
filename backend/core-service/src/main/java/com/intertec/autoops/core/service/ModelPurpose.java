package com.intertec.autoops.core.service;

/**
 * What a model is FOR.
 *
 * <p>A vendor's "list models" call returns everything the account can reach in
 * one flat array — AWS answered with 119 ids, of which 15 embed, 14 generate
 * images and one reranks. Offering that whole list as "default model" invites
 * picking an embedding model to hold a conversation with, which fails at the
 * first call with a vendor error that explains nothing.
 *
 * <p>{@link #CHAT} is the default bucket, so a model this classifier has never
 * seen still appears where it used to. Nothing is hidden by being unrecognised.
 */
public enum ModelPurpose {

    /** Text in, text out — what an agent talks to. */
    CHAT,
    /** Text in, vector out — retrieval and similarity, never conversation. */
    EMBEDDING,
    /** Scores documents against a query; not a generator at all. */
    RERANK,
    IMAGE,
    AUDIO,
    VIDEO
}
