import os
import json
import requests
import jwt
from flask import Flask, request, jsonify
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

app = Flask(__name__)

TENANT_ID = os.environ["TENANT_ID"]
API_AUDIENCE = os.environ["API_AUDIENCE"]
COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"]
DATABASE_NAME = os.environ["COSMOS_DATABASE"]
CONTAINER_NAME = os.environ["COSMOS_CONTAINER"]

ISSUER = os.environ["TOKEN_ISSUER"]
JWKS_URL = f"https://login.microsoftonline.com/{TENANT_ID}/discovery/v2.0/keys"

credential = DefaultAzureCredential()
cosmos_client = CosmosClient(COSMOS_ENDPOINT, credential=credential)
container = cosmos_client.get_database_client(DATABASE_NAME).get_container_client(CONTAINER_NAME)

def validate_token():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None, ("Missing Bearer token", 401)

    token = auth.split(" ", 1)[1]

    try:
        jwks = requests.get(JWKS_URL, timeout=10).json()
        header = jwt.get_unverified_header(token)
        kid = header.get("kid")

        key = next((k for k in jwks["keys"] if k["kid"] == kid), None)

        if not key:
            return None, ("Signing key not found", 401)

        public_key = jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(key))

        claims = jwt.decode(
            token,
            public_key,
            algorithms=["RS256"],
            audience=API_AUDIENCE,
            issuer=ISSUER
        )

        return claims, None

    except Exception as e:
        return None, (f"Invalid token: {str(e)}", 401)


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({
        "status": "healthy",
        "service": "capstone-backend"
    })


@app.route("/api/tasks", methods=["GET"])
def get_tasks():
    claims, error = validate_token()

    if error:
        return jsonify({"error": error[0]}), error[1]

    user_id = claims.get("oid") or claims.get("sub")

    try:
        query = "SELECT * FROM c WHERE c.userId = @userId"

        items = list(
            container.query_items(
                query=query,
                parameters=[
                    {
                        "name": "@userId",
                        "value": user_id
                    }
                ],
                enable_cross_partition_query=False
            )
        )

        return jsonify(items)

    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/tasks", methods=["POST"])
def create_task():
    claims, error = validate_token()

    if error:
        return jsonify({"error": error[0]}), error[1]

    user_id = claims.get("oid") or claims.get("sub")

    data = request.get_json(silent=True) or {}

    if not data.get("title"):
        return jsonify({"error": "title is required"}), 400

    item = {
        "id": data.get("id") or os.urandom(8).hex(),
        "userId": user_id,
        "title": data["title"],
        "description": data.get("description", ""),
        "status": data.get("status", "Pending")
    }

    try:
        created = container.create_item(item)
        return jsonify(created), 201

    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/tasks/<task_id>", methods=["PUT"])
def update_task(task_id):
    claims, error = validate_token()

    if error:
        return jsonify({"error": error[0]}), error[1]

    user_id = claims.get("oid") or claims.get("sub")
    data = request.get_json(silent=True) or {}

    if not data.get("title"):
        return jsonify({"error": "title is required"}), 400

    try:
        existing = container.read_item(
            item=task_id,
            partition_key=user_id
        )

        existing["title"] = data["title"]
        existing["description"] = data.get(
            "description",
            existing.get("description", "")
        )
        existing["status"] = data.get(
            "status",
            existing.get("status", "Pending")
        )

        updated = container.replace_item(
            item=task_id,
            body=existing
        )

        return jsonify(updated), 200

    except Exception as e:
        if "NotFound" in str(e):
            return jsonify({"error": "Task not found"}), 404

        return jsonify({"error": str(e)}), 500


@app.route("/api/tasks/<task_id>", methods=["DELETE"])
def delete_task(task_id):
    claims, error = validate_token()

    if error:
        return jsonify({"error": error[0]}), 401

    user_id = claims.get("oid") or claims.get("sub")

    try:
        container.delete_item(
            item=task_id,
            partition_key=user_id
        )

        return jsonify({
            "message": "Task deleted successfully"
        }), 200

    except Exception as e:
        if "NotFound" in str(e):
            return jsonify({"error": "Task not found"}), 404

        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=8000
    )
