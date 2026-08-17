package com.intertec.autoops.auth.service;

import com.intertec.autoops.auth.config.AuthProperties;
import com.intertec.autoops.auth.domain.AuditEventType;
import com.intertec.autoops.auth.domain.OtpDeliveryStatus;
import com.intertec.autoops.auth.domain.OtpEntry;
import com.intertec.autoops.auth.repo.OtpRepository;
import com.sendgrid.Request;
import com.sendgrid.Response;
import com.sendgrid.SendGrid;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SendGridEmailServiceTest {

    @Mock
    private SendGrid sendGrid;
    @Mock
    private OtpRepository otpRepository;
    @Mock
    private AuditService auditService;

    private SendGridEmailService service;
    private OtpEntry entry;

    private static final OtpEmailEvent EVENT =
            new OtpEmailEvent(1L, "a@example.com", "123456", "tenant-a", "1.2.3.4");

    @BeforeEach
    void setUp() {
        service = new SendGridEmailService(sendGrid, otpRepository, new AuthProperties(),
                auditService);
        entry = new OtpEntry();
        entry.setId(1L);
        when(otpRepository.findById(1L)).thenReturn(Optional.of(entry));
    }

    private static Response response(int status, String body) {
        return new Response(status, body, Map.of());
    }

    @Test
    void acceptedSendIsMarkedSentWithTheMessageId() throws Exception {
        when(sendGrid.api(any(Request.class)))
                .thenReturn(new Response(202, "", Map.of("X-Message-Id", "msg-1")));

        service.onOtpGenerated(EVENT);

        assertEquals(OtpDeliveryStatus.SENT, entry.getDeliveryStatus());
        assertEquals("msg-1", entry.getSendgridMessageId());
        verify(auditService).record(eq(AuditEventType.OTP_SENT), any(), eq("a@example.com"),
                eq("tenant-a"), any(), any(), any(), any());
    }

    @Test
    void retryThatSucceedsWithoutAMessageIdHeaderIsStillSent() throws Exception {
        // Regression: success was previously inferred from (messageId != null ||
        // lastError == null). A 5xx first attempt followed by a 2xx carrying no
        // X-Message-Id satisfied neither, so a DELIVERED code was marked FAILED
        // and the user was told delivery had failed.
        when(sendGrid.api(any(Request.class)))
                .thenReturn(response(503, "{\"errors\":[{\"message\":\"temporarily unavailable\"}]}"))
                .thenReturn(response(202, ""));

        service.onOtpGenerated(EVENT);

        assertEquals(OtpDeliveryStatus.SENT, entry.getDeliveryStatus());
        assertNull(entry.getSendgridMessageId());
        verify(sendGrid, times(2)).api(any(Request.class));
    }

    @Test
    void rejectionRecordsSendGridsOwnReasonNotJustTheStatus() throws Exception {
        // The body is the only place SendGrid says WHY; logging "HTTP 403"
        // alone turned every misconfiguration into an unexplained failure.
        when(sendGrid.api(any(Request.class))).thenReturn(response(403,
                "{\"errors\":[{\"message\":\"The from address does not match a verified "
                        + "Sender Identity.\"}]}"));

        service.onOtpGenerated(EVENT);

        assertEquals(OtpDeliveryStatus.FAILED, entry.getDeliveryStatus());
        ArgumentCaptor<String> detail = ArgumentCaptor.forClass(String.class);
        verify(auditService).record(eq(AuditEventType.OTP_DELIVERY_FAILED), any(),
                eq("a@example.com"), eq("tenant-a"), any(), any(), any(), detail.capture());
        assertTrue(detail.getValue().contains("403"), detail.getValue());
        assertTrue(detail.getValue().contains("verified Sender Identity"), detail.getValue());
    }

    @Test
    void configurationRejectionsAreNotRetried() throws Exception {
        // A 403 cannot succeed on an identical immediate retry — one call only.
        when(sendGrid.api(any(Request.class))).thenReturn(response(403, "{\"errors\":[]}"));

        service.onOtpGenerated(EVENT);

        verify(sendGrid, times(1)).api(any(Request.class));
        assertEquals(OtpDeliveryStatus.FAILED, entry.getDeliveryStatus());
    }

    @Test
    void rateLimitsAndServerErrorsAreRetried() throws Exception {
        when(sendGrid.api(any(Request.class))).thenReturn(response(429, "{\"errors\":[]}"));

        service.onOtpGenerated(EVENT);

        verify(sendGrid, times(2)).api(any(Request.class));
        assertEquals(OtpDeliveryStatus.FAILED, entry.getDeliveryStatus());
    }
}