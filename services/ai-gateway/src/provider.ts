import { randomUUID } from "node:crypto";
import type {
  Suggestion,
  SuggestionProvider,
  SuggestionRequest,
  SuggestionResponse,
  TranscriptSegment,
} from "./types.js";

/**
 * Deterministic development provider. It keeps the gateway usable in tests without
 * sending any content off-device. Replace through dependency injection with a
 * schema-constrained provider adapter in production.
 */
export class DeterministicSuggestionProvider implements SuggestionProvider {
  async suggest(request: SuggestionRequest): Promise<SuggestionResponse> {
    const suggestions: Suggestion[] = [];
    const first = request.transcript[0];
    const last = request.transcript.at(-1);

    if (first && last && request.kinds.includes("title")) {
      suggestions.push(this.title(first));
    }
    if (first && last && request.kinds.includes("chapter")) {
      suggestions.push(this.chapter(first, last));
    }
    if (first && last && request.kinds.includes("socialClip")) {
      suggestions.push(this.socialClip(request.transcript));
    }

    return {
      schemaVersion: 1,
      inputHash: request.inputHash,
      provider: {
        id: "deterministic-local",
        model: "rules",
        version: "0.1.0",
      },
      suggestions,
    };
  }

  private title(first: TranscriptSegment): Suggestion {
    const words = first.text.trim().split(/\s+/).slice(0, 9).join(" ");
    return {
      id: randomUUID(),
      kind: "title",
      startUs: first.startUs,
      endUs: first.endUs,
      confidence: 0.55,
      reason: "Drafted from the opening transcript segment.",
      evidence: [{ type: "transcriptRange", startUs: first.startUs, endUs: first.endUs }],
      payload: { title: words || "Untitled recording" },
    };
  }

  private chapter(first: TranscriptSegment, last: TranscriptSegment): Suggestion {
    return {
      id: randomUUID(),
      kind: "chapter",
      startUs: first.startUs,
      endUs: last.endUs,
      confidence: 0.35,
      reason: "Bootstrap provider creates one full-range chapter.",
      evidence: [{ type: "transcriptRange", startUs: first.startUs, endUs: last.endUs }],
      payload: { title: "Full recording" },
    };
  }

  private socialClip(segments: TranscriptSegment[]): Suggestion {
    const ranked = [...segments].sort((a, b) => b.text.length - a.text.length);
    const segment = ranked[0]!;
    return {
      id: randomUUID(),
      kind: "socialClip",
      startUs: segment.startUs,
      endUs: segment.endUs,
      confidence: 0.25,
      reason: "Bootstrap heuristic selects the densest transcript segment.",
      evidence: [{ type: "transcriptRange", startUs: segment.startUs, endUs: segment.endUs }],
      payload: { targetAspect: "vertical" },
    };
  }
}
