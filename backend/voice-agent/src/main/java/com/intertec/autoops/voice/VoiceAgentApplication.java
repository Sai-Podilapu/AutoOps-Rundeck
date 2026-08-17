package com.intertec.autoops.voice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class VoiceAgentApplication {

    public static void main(String[] args) {
        SpringApplication.run(VoiceAgentApplication.class, args);
    }
}