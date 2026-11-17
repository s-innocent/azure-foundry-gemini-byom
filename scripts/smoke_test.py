#!/usr/bin/env python3
"""
End-to-end smoke test for a Google Gemini BYOM (ModelGateway) connection
in Microsoft Foundry Agent Service (Agents v2).

Prerequisites:
  1. az login (with 'Azure AI User' role on the Foundry project/resource)
  2. pip install -r requirements.txt
  3. Set FOUNDRY_PROJECT_ENDPOINT and FOUNDRY_MODEL_DEPLOYMENT (or copy .env.example to .env)
"""

from __future__ import annotations

import os
import sys
import time

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv


def require_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value or "<your-" in value:
        print(f"ERROR: Set {name} in your environment or .env file.", file=sys.stderr)
        sys.exit(1)
    return value


def main() -> None:
    load_dotenv()

    project_endpoint = require_env("FOUNDRY_PROJECT_ENDPOINT")
    model_deployment = os.getenv(
        "FOUNDRY_MODEL_DEPLOYMENT", "gemini-byom/gemini-3.5-flash-lite"
    ).strip()

    if "/" not in model_deployment:
        print(
            f"ERROR: FOUNDRY_MODEL_DEPLOYMENT='{model_deployment}' must use the format "
            "'<connection-name>/<model-name>' (for example, 'gemini-byom/gemini-3.5-flash-lite').",
            file=sys.stderr,
        )
        sys.exit(1)

    agent_name = "gemini-byom-smoke-test"
    created_version: str | None = None

    print(f"Project endpoint : {project_endpoint}")
    print(f"Connected model  : {model_deployment}")

    with (
        DefaultAzureCredential() as credential,
        AIProjectClient(endpoint=project_endpoint, credential=credential) as project,
    ):
        try:
            agent = project.agents.create_version(
                agent_name=agent_name,
                definition=PromptAgentDefinition(
                    model=model_deployment,
                    instructions="Reply concisely in one short sentence.",
                ),
                description="Temporary smoke-test agent for Gemini BYOM verification.",
            )
            created_version = agent.version
            print(f"Created temporary agent: {agent.name} (version {created_version})")

            start = time.perf_counter()
            with project.get_openai_client(agent_name=agent.name) as openai_client:
                response = openai_client.responses.create(
                    input="Ping! Confirm in one short sentence that you are responding through Microsoft Foundry."
                )
            elapsed_ms = (time.perf_counter() - start) * 1000

            print(f"\nSUCCESS ({elapsed_ms:.0f} ms)")
            print(f"Reply : {response.output_text}")
            if getattr(response, "usage", None):
                print(
                    f"Tokens: input={response.usage.input_tokens}, "
                    f"output={response.usage.output_tokens}, "
                    f"total={response.usage.total_tokens}"
                )
        finally:
            if created_version is not None:
                project.agents.delete_version(
                    agent_name=agent_name,
                    agent_version=created_version,
                )
                print(f"Cleaned up temporary agent: {agent_name} (version {created_version})")


if __name__ == "__main__":
    main()
