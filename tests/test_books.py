from __future__ import annotations

from httpx import AsyncClient


async def test_create_and_fetch(client: AsyncClient, sample_book: dict[str, object]) -> None:
    created = await client.post("/api/v1/books", json=sample_book)
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["id"] > 0
    assert body["title"] == sample_book["title"]
    assert body["created_at"]

    fetched = await client.get(f"/api/v1/books/{body['id']}")
    assert fetched.status_code == 200
    assert fetched.json() == body


async def test_duplicate_isbn_is_conflict(
    client: AsyncClient, sample_book: dict[str, object]
) -> None:
    assert (await client.post("/api/v1/books", json=sample_book)).status_code == 201
    dup = await client.post("/api/v1/books", json=sample_book)
    assert dup.status_code == 409


async def test_validation_rejects_bad_payload(client: AsyncClient) -> None:
    resp = await client.post(
        "/api/v1/books",
        json={"title": "", "author": "x", "isbn": "too-short"},
    )
    assert resp.status_code == 422


async def test_get_missing_book_is_404(client: AsyncClient) -> None:
    assert (await client.get("/api/v1/books/999999")).status_code == 404


async def test_list_pagination_and_total(seeded_client: AsyncClient) -> None:
    resp = await seeded_client.get("/api/v1/books", params={"limit": 2, "offset": 0})
    assert resp.status_code == 200
    page = resp.json()
    assert page["total"] == 5
    assert page["limit"] == 2
    assert len(page["items"]) == 2

    page2 = (await seeded_client.get("/api/v1/books", params={"limit": 2, "offset": 4})).json()
    assert len(page2["items"]) == 1


async def test_list_filters_by_genre(seeded_client: AsyncClient) -> None:
    resp = await seeded_client.get("/api/v1/books", params={"genre": "science fiction"})
    assert resp.status_code == 200
    genres = {item["genre"] for item in resp.json()["items"]}
    assert genres == {"science fiction"}


async def test_search_matches_title(seeded_client: AsyncClient) -> None:
    resp = await seeded_client.get("/api/v1/books", params={"q": "darkness"})
    titles = [item["title"] for item in resp.json()["items"]]
    assert titles == ["The Left Hand of Darkness"]


async def test_patch_updates_fields(client: AsyncClient, sample_book: dict[str, object]) -> None:
    book_id = (await client.post("/api/v1/books", json=sample_book)).json()["id"]
    resp = await client.patch(f"/api/v1/books/{book_id}", json={"in_stock": 42, "price": 9.99})
    assert resp.status_code == 200
    body = resp.json()
    assert body["in_stock"] == 42
    assert body["price"] == 9.99
    assert body["title"] == sample_book["title"]  # untouched


async def test_delete_then_gone(client: AsyncClient, sample_book: dict[str, object]) -> None:
    book_id = (await client.post("/api/v1/books", json=sample_book)).json()["id"]
    assert (await client.delete(f"/api/v1/books/{book_id}")).status_code == 204
    assert (await client.get(f"/api/v1/books/{book_id}")).status_code == 404
    assert (await client.delete(f"/api/v1/books/{book_id}")).status_code == 404
