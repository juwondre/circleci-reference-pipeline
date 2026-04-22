def test_list_items_starts_empty(client):
    r = client.get("/items")
    assert r.status_code == 200
    assert r.get_json() == []


def test_create_item_round_trip(client):
    r = client.post("/items", json={"name": "widget"})
    assert r.status_code == 201
    body = r.get_json()
    assert body["name"] == "widget"
    assert "id" in body
    assert "created_at" in body

    r2 = client.get("/items")
    names = [row["name"] for row in r2.get_json()]
    assert names == ["widget"]


def test_create_item_rejects_blank_name(client):
    r = client.post("/items", json={"name": "   "})
    assert r.status_code == 400
    assert "error" in r.get_json()
