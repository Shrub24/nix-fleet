import uvicorn
from notification_api.main import HOST, PORT


def run():
    uvicorn.run(
        "notification_api.main:app",
        host=HOST,
        port=PORT,
        log_level="info",
    )


if __name__ == "__main__":
    run()
