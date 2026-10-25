
import json
import pytest
import app as challenge


@pytest.fixture
def client():
    challenge.app.config["TESTING"] = True
    challenge.ADMIN_TOKENS.clear()
    return challenge.app.test_client()


def test_status(client):
    response = client.get("/api/status")
    assert response.status_code == 200


def test_public_document(client):
    response = client.get("/api/files?file=guide.txt")
    assert response.status_code == 200
    assert "User Guide" in response.get_json()["content"]


def test_simulated_config_is_disclosed(client):
    response = client.get("/api/files?file=../.env")
    assert response.status_code == 200
    assert "ADMIN_API_KEY=" in response.get_json()["content"]


def test_traversal_cannot_escape_challenge_root(client):
    response = client.get(
        "/api/files?file=../../../../etc/passwd"
    )
    assert response.status_code == 403


def test_download_endpoint_rejects_traversal(client):
    response = client.get("/api/download?file=../.env")
    assert response.status_code == 400


def test_admin_flag_requires_authentication(client):
    response = client.get("/api/admin/flag")
    assert response.status_code == 401


def test_admin_authentication(client):
    response = client.post(
        "/api/admin/login",
        json={"api_key": "HNS-DEMO-ADMIN-KEY-7f3c9a"}
    )
    assert response.status_code == 200

    token = response.get_json()["token"]

    flag_response = client.get(
        "/api/admin/flag",
        headers={"Authorization": f"Bearer {token}"}
    )

    assert flag_response.status_code == 200
    assert flag_response.get_json()["flag"] == (
        "HNS{lfi_to_admin_key_demo}"
    )
