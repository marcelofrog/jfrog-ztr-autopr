package com.example.app;

import java.time.Clock;
import org.apache.commons.lang3.StringUtils;

/** Builds greetings. The clock is injectable so tests are deterministic. */
public class GreetingService {

    static final String DEFAULT_NAME = "World";

    private final Clock clock;

    public GreetingService(Clock clock) {
        this.clock = clock;
    }

    public Greeting greet(String rawName) {
        String name = StringUtils.capitalize(StringUtils.defaultIfBlank(StringUtils.trim(rawName), DEFAULT_NAME));
        return new Greeting("Hello, " + name + "!", name, clock.instant());
    }
}
