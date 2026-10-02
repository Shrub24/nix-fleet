package main

import "github.com/maximhq/bifrost/core/schemas"

func GetName() string { return "voyage-normalizer" }

func Cleanup() error { return nil }

func PreLLMHook(
	ctx *schemas.BifrostContext,
	req *schemas.BifrostRequest,
) (*schemas.BifrostRequest, *schemas.LLMPluginShortCircuit, error) {
	if req == nil || req.EmbeddingRequest == nil || string(req.EmbeddingRequest.Provider) != "voyage" {
		return req, nil, nil
	}

	params := req.EmbeddingRequest.Params
	if params == nil {
		return req, nil, nil
	}

	if params.EncodingFormat != nil && *params.EncodingFormat == schemas.EmbeddingEncodingFloat {
		params.EncodingFormat = nil
	}

	if params.Dimensions != nil {
		if params.ExtraParams == nil {
			params.ExtraParams = make(map[string]interface{})
		}
		if nested, ok := params.ExtraParams["extra_params"].(map[string]interface{}); ok {
			delete(params.ExtraParams, "extra_params")
			for key, value := range nested {
				if _, exists := params.ExtraParams[key]; !exists {
					params.ExtraParams[key] = value
				}
			}
		}
		if _, hasNativeDimension := params.ExtraParams["output_dimension"]; !hasNativeDimension {
			params.ExtraParams["output_dimension"] = *params.Dimensions
		}
		params.Dimensions = nil
		if ctx != nil {
			// Bifrost only serializes ExtraParams when this per-request flag is set.
			ctx.SetValue(schemas.BifrostContextKeyPassthroughExtraParams, true)
		}
	}

	return req, nil, nil
}

// The entrypoint package is built as a Go plugin by Bifrost's pinned toolchain.
func main() {}
