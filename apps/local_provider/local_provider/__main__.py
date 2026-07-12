from __future__ import annotations

import asyncio
import logging

from .application import Application
from .config import Settings


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    asyncio.run(run())


async def run() -> None:
    await Application(Settings.from_env()).run()


if __name__ == "__main__":
    main()
