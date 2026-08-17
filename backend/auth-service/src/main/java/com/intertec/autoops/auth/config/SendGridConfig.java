package com.intertec.autoops.auth.config;

import com.sendgrid.Client;
import com.sendgrid.SendGrid;
import org.apache.http.client.config.RequestConfig;
import org.apache.http.impl.client.CloseableHttpClient;
import org.apache.http.impl.client.HttpClients;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * SendGrid v3 client with bounded timeouts (3s) so a slow email provider can
 * never stall a login request beyond the retry budget.
 */
@Configuration
public class SendGridConfig {

    private static final int TIMEOUT_MILLIS = 3_000;

    @Bean
    public SendGrid sendGrid(AuthProperties properties) {
        RequestConfig requestConfig = RequestConfig.custom()
                .setConnectTimeout(TIMEOUT_MILLIS)
                .setConnectionRequestTimeout(TIMEOUT_MILLIS)
                .setSocketTimeout(TIMEOUT_MILLIS)
                .build();
        CloseableHttpClient httpClient = HttpClients.custom()
                .setDefaultRequestConfig(requestConfig)
                .build();
        return new SendGrid(properties.getSendgrid().getApiKey(), new Client(httpClient));
    }
}
