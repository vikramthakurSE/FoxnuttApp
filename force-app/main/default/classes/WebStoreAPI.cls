/**
 * Public REST API for the nutty-nirvana website.
 * Consumed server-to-server by the Next.js backend via a Connected App
 * (OAuth 2.0 Client Credentials flow) — never called from the browser.
 *
 *   GET  /services/apexrest/store/v1/catalog          → product catalog + availability
 *   GET  /services/apexrest/store/v1/orders?phone=... → order history for a phone
 *   POST /services/apexrest/store/v1/orders           → place an order
 */
@RestResource(urlMapping='/store/v1/*')
global with sharing class WebStoreAPI {

    @HttpGet
    global static void doGet() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            String path = req.requestURI.toLowerCase();
            if (path.endsWith('/catalog')) {
                respond(res, 200, new Map<String, Object>{
                    'products' => WebStoreService.getCatalog()
                });
            } else if (path.contains('/verify-code')) {
                // Resolve a client's login code to their account. Returns
                // 200 with found=false rather than 404, so the website can
                // tell "wrong code" apart from "endpoint is down".
                Account a = WebStoreService.findClientByCode(
                    req.params.get('code'));
                Map<String, Object> out = new Map<String, Object>{
                    'found' => a != null
                };
                if (a != null) {
                    out.put('accountId',   a.Id);
                    out.put('accountName', a.Name);
                    out.put('phone',       a.Phone_Digits__c);
                    out.put('code',        a.Unique_Business_Code__c);
                    out.put('gstin',       a.GSTIN__c);
                    out.put('address', String.join(
                        new List<String>{
                            a.BillingStreet, a.BillingCity,
                            a.BillingState, a.BillingPostalCode
                        }, ', ').replaceAll('(, )+', ', ')
                         .removeStart(', ').removeEnd(', '));
                }
                respond(res, 200, out);
            } else if (path.contains('/orders')) {
                // Orders are addressable by code or by phone; the code is
                // what the website holds after login.
                String phone = req.params.get('phone');
                String code  = req.params.get('code');
                if (String.isNotBlank(code)) {
                    Account a = WebStoreService.findClientByCode(code);
                    phone = (a == null) ? null : a.Phone_Digits__c;
                }
                respond(res, 200, new Map<String, Object>{
                    'orders' => String.isBlank(phone)
                        ? new List<Object>()
                        : WebStoreService.getOrders(phone)
                });
            } else {
                respond(res, 404, error('Unknown resource.'));
            }
        } catch (Exception e) {
            respond(res, 500, error(e.getMessage()));
        }
    }

    @HttpPost
    global static void doPost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            String path = req.requestURI.toLowerCase();

            // Resend an existing client's login code to their WhatsApp.
            if (path.contains('/request-code')) {
                Map<String, Object> body =
                    (Map<String, Object>) JSON.deserializeUntyped(
                        req.requestBody.toString());
                Boolean sent = WebStoreService.requestCodeByPhone(
                    (String) body.get('phone'));
                // 200 either way: the website needs to tell "not registered"
                // apart from "the service is down".
                respond(res, 200, new Map<String, Object>{ 'sent' => sent });
                return;
            }

            // Register a walk-up customer.
            if (path.contains('/register')) {
                WebStoreService.RegisterInput reg =
                    (WebStoreService.RegisterInput) JSON.deserialize(
                        req.requestBody.toString(),
                        WebStoreService.RegisterInput.class
                    );
                WebStoreService.RegisterResult result =
                    WebStoreService.registerClient(reg);
                respond(res, result.alreadyRegistered ? 200 : 201,
                        new Map<String, Object>{ 'account' => result });
                return;
            }

            // Customer cancels their own order.
            if (path.contains('/cancel-order')) {
                Map<String, Object> body =
                    (Map<String, Object>) JSON.deserializeUntyped(
                        req.requestBody.toString());
                WebStoreService.OrderEditResult r =
                    WebStoreService.cancelOrder(
                        (String) body.get('businessCode'),
                        (Id) body.get('saleId'));
                respond(res, 200, new Map<String, Object>{ 'order' => r });
                return;
            }

            // Customer changes quantities on their own order.
            if (path.contains('/modify-order')) {
                Map<String, Object> body =
                    (Map<String, Object>) JSON.deserializeUntyped(
                        req.requestBody.toString());
                Map<Id, Integer> packets = new Map<Id, Integer>();
                Object raw = body.get('lines');
                if (raw instanceof Map<String, Object>) {
                    for (String lineId :
                         ((Map<String, Object>) raw).keySet()) {
                        Object v = ((Map<String, Object>) raw).get(lineId);
                        packets.put((Id) lineId, Integer.valueOf(v));
                    }
                }
                WebStoreService.OrderEditResult r =
                    WebStoreService.modifyOrder(
                        (String) body.get('businessCode'),
                        (Id) body.get('saleId'),
                        packets);
                respond(res, 200, new Map<String, Object>{ 'order' => r });
                return;
            }

            if (!path.contains('/orders')) {
                respond(res, 404, error('Unknown resource.'));
                return;
            }
            WebStoreService.OrderInput input =
                (WebStoreService.OrderInput) JSON.deserialize(
                    req.requestBody.toString(),
                    WebStoreService.OrderInput.class
                );
            WebStoreService.OrderResult result =
                WebStoreService.placeOrder(input);
            respond(res, result.duplicate ? 200 : 201,
                    new Map<String, Object>{ 'order' => result });
        } catch (WebStoreService.WebStoreException e) {
            respond(res, 400, error(e.getMessage()));
        } catch (Exception e) {
            respond(res, 500, error(e.getMessage()));
        }
    }

    private static void respond(RestResponse res, Integer code, Object body) {
        res.statusCode   = code;
        res.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    private static Map<String, Object> error(String message) {
        return new Map<String, Object>{ 'error' => message };
    }
}
