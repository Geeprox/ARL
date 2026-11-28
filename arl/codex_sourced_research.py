"""Versioned sourced research over the existing Codex transport and ARL worker.

This opt-in composition installs no grants and starts no process on discovery.
The earlier text-only candidate remains a separate, unadopted v1 contract.
"""
from __future__ import annotations

from . import codex_sourced_contract as contract
from .contracts import encode
from .research import sha
from .codex_server import SOURCED_THREAD_CONTROLS
from .codex_research import (
    CONTROL_CONTRACT as TEXT_CONTROL_CONTRACT, NativeCodexAdapter,
    CodexResearchEngine, CodexResearchGrant, METHODS,
)

NAME = contract.NAME
CONTRACT_SHA256 = contract.CONTRACT_SHA256
CONTROL_CONTRACT = dict(TEXT_CONTROL_CONTRACT,
    renderer_version=contract.RENDERER,
    thread_controls=SOURCED_THREAD_CONTROLS,
    generated_output_schema=contract.OUTPUT_SCHEMA,
    generated_body_bytes=contract.GENERATED_BODY_BYTES,
    native_codec_contract_sha256=CONTRACT_SHA256,
    citation_validation='exact_submitted_source_utf8_range_no_normalization_no_repair')


class CodexSourcedAdapter(NativeCodexAdapter):
    contract = contract
    formats = contract.FORMATS
    contract_sha256 = CONTRACT_SHA256
    control_contract = CONTROL_CONTRACT

    def complete(self, raw, args, context):
        request = contract.request_body(raw, args)
        self.preflight(args)
        selected = args.get('execution_options')
        preferences = {} if selected is None else {'reasoning_effort': selected['thinking_effort'],
            'service_tier': selected['service_tier'], 'selectable': True}
        result = self.text_adapter.run_sourced({
            'model': args['model'], 'input': raw.decode('utf-8'),
            'max_output_bytes': args['max_output_bytes'],
        }, context, **preferences)
        # Revalidate the actual returned structure against the original bytes,
        # even if a supplied transport implementation claims validation.
        output = contract.structured_body(encode(result['structured_output']),
                                          request, args['max_output_bytes'])
        binding, native, evidence = context.native_snapshot()
        envelope = dict(binding, schema_version=2, provider_input_sha256=sha(raw),
            model_evidence=evidence, native=native, text=output['text'],
            citations=output['citations'], output_sha256=contract.output_digest(output),
            reviewed_evidence_bindings=contract.reviewed_bindings(request),
            usage={'tokens': None, 'cost': None}, token_hard_cap_supported=False)
        if selected is not None:
            from .codex_execution_contract import preferences as validate_preferences
            envelope['schema_version'] = 3
            envelope['execution_options'] = selected
            observed = result.get('execution_preferences')
            # Provider-tier diagnostics are internal; the versioned public receipt
            # retains its exact original contract and hash.
            confirmed = ({key: observed[key] for key in ('reasoning_effort', 'service_tier', 'source')
                          if key in observed} if isinstance(observed, dict) else observed)
            envelope['execution_preferences'] = validate_preferences(confirmed, selected)
        reply = encode(envelope)
        self.contract.result_body(reply, args, binding=binding, native=native,
            model_evidence=evidence, reviewed_evidence=envelope['reviewed_evidence_bindings'],
            request=request)
        return reply


class CodexSourcedResearchEngine(CodexResearchEngine):
    name = NAME
    contract = contract
    renderer = contract.RENDERER
    contract_sha256 = CONTRACT_SHA256
    structured_generated_citations = True
    formats = contract.FORMATS
    limits = contract.LIMITS
    request_purpose = contract.REQUEST
    descriptor_purpose = contract.DESCRIPTOR
    response_purpose = contract.RESPONSE
