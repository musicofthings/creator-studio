export type SuggestionKind =
  | "chapter"
  | "socialClip"
  | "focus"
  | "title"
  | "showNotes"
  | "tutorialStep";

export interface TranscriptSegment {
  startUs: number;
  endUs: number;
  text: string;
  speaker?: string;
}

export interface ConsentReceipt {
  id: string;
  purpose: string;
  dataClasses: string[];
  policyVersion: string;
  grantedAt: string;
  signature?: string;
}

export interface SuggestionRequest {
  schemaVersion: 1;
  requestId: string;
  inputHash: string;
  kinds: SuggestionKind[];
  transcript: TranscriptSegment[];
  consent: ConsentReceipt;
}

export interface Suggestion {
  id: string;
  kind: SuggestionKind;
  startUs: number;
  endUs: number;
  confidence: number;
  reason: string;
  evidence: Array<{
    type: "transcriptRange" | "sampledFrameRange" | "interactionRange";
    startUs: number;
    endUs: number;
  }>;
  payload: Record<string, unknown>;
}

export interface SuggestionResponse {
  schemaVersion: 1;
  inputHash: string;
  provider: { id: string; model: string; version: string };
  suggestions: Suggestion[];
}

export interface SuggestionProvider {
  suggest(request: SuggestionRequest): Promise<SuggestionResponse>;
}
