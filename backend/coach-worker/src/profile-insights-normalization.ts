import { profileInsightsJobResultSchema } from "./schemas";
import { normalizeProfileInsightStringArray, cleanPlainParagraph, coerceProfileInsightsExecutionContext } from "./openai";
import type { CoachProfileInsightsJobResult } from "./schemas";

/**
 * Canonicalizes async profile-insights job result to exact schema compliance.
 * This ensures all fields conform to profileInsightsJobResultSchema to prevent
 * 400 "Request body does not match the coach contract" errors.
 */
export function normalizeAsyncProfileInsightsResult(
  result: unknown
): CoachProfileInsightsJobResult | null {
  if (!result || typeof result !== "object") {
    return null;
  }

  try {
    // First, create a clean base object with only known schema fields
    const cleanResult: Record<string, unknown> = {};

    // Copy and normalize top-level fields with exact schema types
    if (typeof (result as any).summary === "string") {
      cleanResult.summary = cleanPlainParagraph((result as any).summary).slice(0, 2200);
    } else {
      cleanResult.summary = "";
    }

    if (Array.isArray((result as any).keyObservations)) {
      cleanResult.keyObservations = normalizeProfileInsightStringArray(
        (result as any).keyObservations,
        8
      );
    } else {
      cleanResult.keyObservations = [];
    }

    if (Array.isArray((result as any).topConstraints)) {
      cleanResult.topConstraints = normalizeProfileInsightStringArray(
        (result as any).topConstraints,
        6
      );
    } else {
      cleanResult.topConstraints = [];
    }

    if (Array.isArray((result as any).recommendations)) {
      cleanResult.recommendations = normalizeProfileInsightStringArray(
        (result as any).recommendations,
        8
      );
    } else {
      cleanResult.recommendations = [];
    }

    if (Array.isArray((result as any).confidenceNotes)) {
      cleanResult.confidenceNotes = normalizeProfileInsightStringArray(
        (result as any).confidenceNotes,
        6
      );
    } else {
      cleanResult.confidenceNotes = [];
    }

    // Handle executionContext with full canonicalization
    if ((result as any).executionContext && typeof (result as any).executionContext === "object") {
      cleanResult.executionContext = coerceProfileInsightsExecutionContext(
        (result as any).executionContext
      );
    }

    // Copy enum and primitive fields with validation
    if (typeof (result as any).generationStatus === "string") {
      const validStatuses = ["model", "fallback"] as const;
      cleanResult.generationStatus = validStatuses.includes((result as any).generationStatus as any)
        ? (result as any).generationStatus
        : "fallback";
    } else {
      cleanResult.generationStatus = "fallback";
    }

    if (typeof (result as any).insightSource === "string") {
      const validSources = ["fallback", "fresh_model", "cached_model"] as const;
      cleanResult.insightSource = validSources.includes((result as any).insightSource as any)
        ? (result as any).insightSource
        : "fallback";
    } else {
      cleanResult.insightSource = "fallback";
    }

    if (typeof (result as any).inferenceMode === "string") {
      const validModes = ["structured", "plain_text"] as const;
      cleanResult.inferenceMode = validModes.includes((result as any).inferenceMode as any)
        ? (result as any).inferenceMode
        : "structured";
    } else {
      cleanResult.inferenceMode = "structured";
    }

    // Optional primitive fields with validation
    if (typeof (result as any).selectedModel === "string") {
      cleanResult.selectedModel = (result as any).selectedModel.slice(0, 200);
    }

    if (typeof (result as any).modelDurationMs === "number" && (result as any).modelDurationMs >= 0) {
      cleanResult.modelDurationMs = (result as any).modelDurationMs;
    }

    if (typeof (result as any).totalJobDurationMs === "number" && (result as any).totalJobDurationMs >= 0) {
      cleanResult.totalJobDurationMs = (result as any).totalJobDurationMs;
    }

    // Validate against schema to ensure exact compliance
    const parseResult = profileInsightsJobResultSchema.safeParse(cleanResult);
    
    if (!parseResult.success) {
      // Log detailed validation issues
      console.error("Async profile insights result normalization failed", {
        error: parseResult.error,
        originalResult: result,
        cleanedResult: cleanResult,
        validationIssues: parseResult.error.issues.map((issue: any) => ({
          path: issue.path.join('.'),
          code: issue.code,
          message: issue.message,
          received: issue.received,
        })),
      });

      // Return a safe fallback result instead of null
      return {
        summary: "Profile insights completed with validation issues",
        keyObservations: [],
        topConstraints: [],
        recommendations: [],
        confidenceNotes: [],
        generationStatus: "fallback" as const,
        insightSource: "fallback" as const,
        inferenceMode: "structured" as const,
        modelDurationMs: 0,
        totalJobDurationMs: 0,
      };
    }

    return parseResult.data;
  } catch (error) {
    console.error("Async profile insights result normalization error", {
      error: error instanceof Error ? error.message : String(error),
      originalResult: result,
    });

    // Return safe fallback on any unexpected error
    return {
      summary: "Profile insights processing error",
      keyObservations: [],
      topConstraints: [],
      recommendations: [],
      confidenceNotes: [],
      generationStatus: "fallback" as const,
      insightSource: "fallback" as const,
      inferenceMode: "structured" as const,
      modelDurationMs: 0,
      totalJobDurationMs: 0,
    };
  }
}
