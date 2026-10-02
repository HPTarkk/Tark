window.onload = function () {
  window.ui = SwaggerUIBundle({
    url: "../openapi.yaml",
    dom_id: "#swagger-ui",
    deepLinking: true,
    displayRequestDuration: true,
    docExpansion: "list",
    filter: true,
    // Never keep a pasted access token in the browser's storage.
    persistAuthorization: false,
    presets: [SwaggerUIBundle.presets.apis],
    layout: "BaseLayout",
  });
};
