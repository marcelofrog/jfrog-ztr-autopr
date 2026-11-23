package com.example.app;

import java.time.Instant;

/** Immutable response payload, serialized to JSON by Jackson. */
public record Greeting(String message, String name, Instant timestamp) {}
