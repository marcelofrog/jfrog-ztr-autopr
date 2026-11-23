package com.example.app;

import static org.assertj.core.api.Assertions.assertThat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Clock;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class AppTest {

    private final ObjectMapper mapper = App.newMapper();
    private final HttpClient client = HttpClient.newHttpClient();
    private HttpServer server;
    private String baseUrl;

    @BeforeEach
    void start() throws Exception {
        server = App.createServer(0, new GreetingService(Clock.systemUTC()), mapper);
        server.start();
        baseUrl = "http://localhost:" + server.getAddress().getPort();
    }

    @AfterEach
    void stop() {
        server.stop(0);
    }

    @Test
    void parseQueryHandlesEncodingAndMissingValues() {
        assertThat(App.parseQuery(null)).isEmpty();
        assertThat(App.parseQuery("name=Jane%20Doe&flag&&x=a=b"))
                .containsEntry("name", "Jane Doe")
                .containsEntry("flag", "")
                .containsEntry("x", "a=b");
    }

    @Test
    void healthReturnsUp() throws Exception {
        JsonNode body = get("/health");

        assertThat(body.get("status").asText()).isEqualTo("UP");
    }

    @Test
    void helloReturnsJsonGreeting() throws Exception {
        JsonNode body = get("/hello?name=jane");

        assertThat(body.get("message").asText()).isEqualTo("Hello, Jane!");
        assertThat(body.get("timestamp").asText()).endsWith("Z");
    }

    private JsonNode get(String path) throws Exception {
        HttpResponse<String> res = client.send(
                HttpRequest.newBuilder(URI.create(baseUrl + path)).GET().build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(res.statusCode()).isEqualTo(200);
        assertThat(res.headers().firstValue("Content-Type")).contains("application/json");
        return mapper.readTree(res.body());
    }
}
