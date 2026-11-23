package com.example.app;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

class GreetingServiceTest {

    private static final Instant NOW = Instant.parse("2025-01-01T00:00:00Z");
    private final GreetingService service = new GreetingService(Clock.fixed(NOW, ZoneOffset.UTC));

    @Test
    void greetsByNameAndCapitalizes() {
        Greeting g = service.greet("  jane ");

        assertThat(g.message()).isEqualTo("Hello, Jane!");
        assertThat(g.name()).isEqualTo("Jane");
        assertThat(g.timestamp()).isEqualTo(NOW);
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {" ", "\t"})
    void fallsBackToDefaultNameWhenBlank(String input) {
        assertThat(service.greet(input).message()).isEqualTo("Hello, World!");
    }
}
