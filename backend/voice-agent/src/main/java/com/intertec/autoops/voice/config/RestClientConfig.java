package com.intertec.autoops.voice.config;

import org.springframework.boot.web.client.RestClientCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.JdkClientHttpRequestFactory;

import java.net.http.HttpClient;
import java.time.Clock;

@Configuration
public class RestClientConfig {

    /**
     * Bounds the one outbound call this service makes. Without a read timeout a
     * hung ElevenLabs connection would pin a Tomcat thread until the container
     * is restarted, and a public endpoint is exactly where that gets noticed.
     */
    @Bean
    public RestClientCustomizer voiceRestClientCustomizer(VoiceProperties properties) {
        return builder -> {
            HttpClient httpClient = HttpClient.newBuilder()
                    .connectTimeout(properties.getRequestTimeout())
                    .build();
            JdkClientHttpRequestFactory factory = new JdkClientHttpRequestFactory(httpClient);
            factory.setReadTimeout(properties.getRequestTimeout());
            builder.requestFactory(factory);
        };
    }

    /** Injected rather than read statically so the rate limiter is testable. */
    @Bean
    public Clock clock() {
        return Clock.systemUTC();
    }
}
