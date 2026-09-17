"""极氪账号认证接口。

流程（国区）：
    1. `POST /api/auth/sendCode`   —— 请求短信验证码
    2. `POST /api/auth/verifyCode` —— 校验验证码，建立会话
    3. `GET  /api/auth/status`     —— 查询登录状态
    4. `POST /api/auth/logout`     —— 登出

注意：极氪每个账号只保留一个会话，新登录会顶掉旧令牌。
建议使用**独立子账号并共享车辆**，避免与手机 App 互相挤下线。
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..adapters import get_client, is_mock
from ..core.config import config

logger = logging.getLogger(__name__)

router = APIRouter()


class SendCodeRequest(BaseModel):
    phone: str = Field(..., description="中国大陆手机号（11 位）")


class VerifyCodeRequest(BaseModel):
    phone: str = Field(..., description="中国大陆手机号")
    code: str = Field(..., description="短信验证码（6 位）")


@router.post("/sendCode")
async def send_code(payload: SendCodeRequest) -> dict:
    """请求短信验证码。"""
    phone = payload.phone.strip()
    if not (phone.isdigit() and len(phone) == 11):
        raise HTTPException(status_code=400, detail="请输入有效的 11 位手机号")

    client = get_client()
    try:
        result = await client.send_sms_code(phone)
    except Exception as exc:  # noqa: BLE001
        logger.error("发送验证码失败：%s", exc)
        raise HTTPException(status_code=500, detail=f"发送验证码失败：{exc}") from exc

    return {
        "success": result.get("success", False),
        "data": result,
        "error": None if result.get("success") else result.get("message"),
    }


@router.post("/verifyCode")
async def verify_code(payload: VerifyCodeRequest) -> dict:
    """校验验证码并建立会话。"""
    phone = payload.phone.strip()
    code = payload.code.strip()

    if not (phone.isdigit() and len(phone) == 11):
        raise HTTPException(status_code=400, detail="请输入有效的 11 位手机号")
    if not (code.isdigit() and len(code) == 6):
        raise HTTPException(status_code=400, detail="请输入 6 位数字验证码")

    client = get_client()
    try:
        result = await client.verify_sms_code(phone, code)
    except Exception as exc:  # noqa: BLE001
        logger.error("验证码校验失败：%s", exc)
        raise HTTPException(status_code=500, detail=f"验证码校验失败：{exc}") from exc

    return {
        "success": result.get("success", False),
        "data": result,
        "error": None if result.get("success") else result.get("message"),
    }


@router.get("/status")
async def auth_status() -> dict:
    """查询登录状态。"""
    client = get_client()
    try:
        authenticated = await client.is_authenticated()
    except Exception as exc:  # noqa: BLE001
        logger.warning("查询登录状态失败：%s", exc)
        authenticated = False

    return {
        "success": True,
        "data": {
            "authenticated": authenticated,
            "mock": is_mock(),
            "configured": config.zeekr.is_configured,
            "missingKeys": config.zeekr.missing_keys(),
            "note": "使用独立子账号并共享车辆，可避免与手机 App 会话冲突",
        },
    }


@router.post("/logout")
async def logout() -> dict:
    """登出并清除本地会话。"""
    client = get_client()
    try:
        await client.logout()
    except Exception as exc:  # noqa: BLE001
        logger.warning("登出失败：%s", exc)

    return {"success": True, "data": {"message": "已登出"}}
