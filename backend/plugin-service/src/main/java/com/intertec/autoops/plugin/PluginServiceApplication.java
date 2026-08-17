package com.intertec.autoops.plugin;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;
import org.springframework.scheduling.annotation.EnableScheduling;

/** Scheduling drives one job only: the delivery-log retention trim. */
@SpringBootApplication
@ConfigurationPropertiesScan
@EnableScheduling
public class PluginServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(PluginServiceApplication.class, args);
    }
}
