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
            } else if (path.contains('/orders')) {
                String phone = req.params.get('phone');
                respond(res, 200, new Map<String, Object>{
                    'orders' => WebStoreService.getOrders(phone)
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
            if (!req.requestURI.toLowerCase().contains('/orders')) {
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
