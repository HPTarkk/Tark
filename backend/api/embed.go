// Package api embeds the API contract and its interactive documentation.
//
// openapi.yaml is the contract the app and the server are both written
// against; the Swagger UI files in swaggerui/ render it at /docs.
package api

import "embed"

// Spec is the OpenAPI document.
//
//go:embed openapi.yaml
var Spec []byte

// UI holds the Swagger UI page and its assets.
//
//go:embed swaggerui
var UI embed.FS
