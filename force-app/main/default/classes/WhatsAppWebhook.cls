/**
 * @description : Public endpoint Meta calls for incoming WhatsApp messages.
 *                Exposed via a Salesforce Site, so guest user access is required.
 * GET  = Meta's one-time webhook verification handshake
 * POST = every incoming message / button tap (processing handed to a Queueable
 *        so we return 200 fast — Meta retries anything slower than ~10s)
 **/
@RestResource(urlMapping='/whatsapp/webhook')
global without sharing class WhatsAppWebhook {

    // Set the SAME value in Meta App Dashboard → WhatsApp → Configuration → Verify token
    private static final String VERIFY_TOKEN = 'FOXNUTT_VERIFY_2026';

    @HttpGet
    global static void verify() {
        RestRequest req  = RestContext.request;
        RestResponse res = RestContext.response;
        if (req.params.get('hub.mode') == 'subscribe'
            && req.params.get('hub.verify_token') == VERIFY_TOKEN) {
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(req.params.get('hub.challenge'));
        } else {
            res.statusCode = 403;
        }
    }

    @HttpPost
    global static void receive() {
        RestContext.response.statusCode = 200; // always ack immediately
        try {
            System.enqueueJob(
                new WhatsAppBotService(RestContext.request.requestBody.toString()));
        } catch (Exception e) {
            // swallow — a failed enqueue must never make Meta retry-storm us
        }
    }
}
