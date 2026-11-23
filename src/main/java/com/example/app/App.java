package com.example.app;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.google.common.base.Splitter;
import com.google.common.collect.ImmutableMap;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Tiny HTTP service: GET /hello?name=Jane and GET /health. Uses only the JDK HTTP server. */
public final class App {

    private static final Logger log = LoggerFactory.getLogger(App.class);

    private App() {}

    public static void main(String[] args) throws IOException {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        HttpServer server = createServer(port, new GreetingService(Clock.systemUTC()), newMapper());
        server.start();
        log.info("Listening on port {}", server.getAddress().getPort());
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log.info("Shutting down");
            server.stop(1);
        }));
    }

    static ObjectMapper newMapper() {
        return new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    }

    /** Creates (but does not start) the server. Pass port 0 to pick a free port. */
    static HttpServer createServer(int port, GreetingService service, ObjectMapper mapper) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/health", ex -> respond(ex, mapper, 200, ImmutableMap.of("status", "UP")));
        server.createContext("/hello", ex -> {
            String name = parseQuery(ex.getRequestURI().getRawQuery()).get("name");
            respond(ex, mapper, 200, service.greet(name));
        });
        return server;
    }

    static Map<String, String> parseQuery(String rawQuery) {
        Map<String, String> params = new HashMap<>();
        if (rawQuery == null) {
            return params;
        }
        for (String pair : Splitter.on('&').omitEmptyStrings().split(rawQuery)) {
            List<String> kv = Splitter.on('=').limit(2).splitToList(pair);
            String value = kv.size() > 1 ? kv.get(1) : "";
            params.put(decode(kv.get(0)), decode(value));
        }
        return params;
    }

    private static String decode(String s) {
        return URLDecoder.decode(s, StandardCharsets.UTF_8);
    }

    private static void respond(HttpExchange ex, ObjectMapper mapper, int status, Object body) throws IOException {
        byte[] bytes = mapper.writeValueAsBytes(body);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (var out = ex.getResponseBody()) {
            out.write(bytes);
        }
        log.debug("{} {} -> {}", ex.getRequestMethod(), ex.getRequestURI(), status);
    }
}
