"""
ComfyUI API helper module for pipeline automation.

Provides functions to queue workflows, poll for completion,
and download output images/meshes from ComfyUI instances.

Usage:
    from comfyui_api import ComfyUIClient

    client = ComfyUIClient("http://localhost:8188")
    workflow = client.load_workflow("~/comfyui/flows/flux-concept-art.json")
    workflow = client.set_node_input(workflow, "6", "text", "a red dragon")
    prompt_id = client.queue(workflow)
    result = client.wait(prompt_id)
    client.download_images(prompt_id, dest_dir="~/assets/concepts/")
"""

import json
import os
import sys
import time
import uuid
import urllib.request
import urllib.parse
import urllib.error


class ComfyUIClient:
    def __init__(self, server_url: str = "http://localhost:8188"):
        self.server = server_url.rstrip("/")
        self.client_id = str(uuid.uuid4())

    def queue(self, workflow: dict) -> str:
        """Submit a workflow and return the prompt_id."""
        payload = json.dumps({
            "prompt": workflow,
            "client_id": self.client_id,
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{self.server}/prompt",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        resp = urllib.request.urlopen(req)
        data = json.loads(resp.read())
        return data["prompt_id"]

    def wait(self, prompt_id: str, timeout: int = 600, poll_interval: float = 2.0) -> dict:
        """Poll /history until the prompt completes or times out."""
        start = time.time()
        while time.time() - start < timeout:
            try:
                req = urllib.request.Request(f"{self.server}/history/{prompt_id}")
                resp = urllib.request.urlopen(req)
                history = json.loads(resp.read())
                if prompt_id in history:
                    status = history[prompt_id].get("status", {})
                    if status.get("completed", False):
                        return history[prompt_id]
                    if status.get("status_str") == "error":
                        raise RuntimeError(f"Workflow error: {status}")
            except urllib.error.URLError:
                pass
            time.sleep(poll_interval)
        raise TimeoutError(f"Workflow {prompt_id} timed out after {timeout}s")

    def get_output_images(self, prompt_id: str) -> list[dict]:
        """Get output image metadata from completed workflow."""
        req = urllib.request.Request(f"{self.server}/history/{prompt_id}")
        resp = urllib.request.urlopen(req)
        history = json.loads(resp.read())
        images = []
        for node_id, node_output in history[prompt_id]["outputs"].items():
            for img in node_output.get("images", []):
                img["_node_id"] = node_id
                images.append(img)
        return images

    def download_image(self, image_meta: dict, dest_path: str) -> str:
        """Download a single output image to dest_path."""
        params = urllib.parse.urlencode({
            "filename": image_meta["filename"],
            "subfolder": image_meta.get("subfolder", ""),
            "type": image_meta.get("type", "output"),
        })
        url = f"{self.server}/view?{params}"
        req = urllib.request.Request(url)
        resp = urllib.request.urlopen(req)
        data = resp.read()

        os.makedirs(os.path.dirname(dest_path) or ".", exist_ok=True)
        with open(dest_path, "wb") as f:
            f.write(data)
        return dest_path

    def download_images(self, prompt_id: str, dest_dir: str) -> list[str]:
        """Download all output images from a completed workflow."""
        images = self.get_output_images(prompt_id)
        paths = []
        for img in images:
            filename = img["filename"]
            dest = os.path.join(os.path.expanduser(dest_dir), filename)
            self.download_image(img, dest)
            paths.append(dest)
        return paths

    def upload_image(self, filepath: str, subfolder: str = "", image_type: str = "input") -> dict:
        """Upload an image to ComfyUI for use in workflows."""
        filepath = os.path.expanduser(filepath)
        filename = os.path.basename(filepath)

        with open(filepath, "rb") as f:
            file_data = f.read()

        boundary = uuid.uuid4().hex
        body = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="image"; filename="{filename}"\r\n'
            f"Content-Type: application/octet-stream\r\n\r\n"
        ).encode() + file_data + (
            f"\r\n--{boundary}\r\n"
            f'Content-Disposition: form-data; name="subfolder"\r\n\r\n'
            f"{subfolder}\r\n"
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="type"\r\n\r\n'
            f"{image_type}\r\n"
            f"--{boundary}--\r\n"
        ).encode()

        req = urllib.request.Request(
            f"{self.server}/upload/image",
            data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read())

    @staticmethod
    def load_workflow(path: str) -> dict:
        """Load a workflow JSON from file."""
        path = os.path.expanduser(path)
        with open(path) as f:
            return json.load(f)

    @staticmethod
    def set_node_input(workflow: dict, node_id: str, field: str, value) -> dict:
        """Set an input field on a workflow node. Returns the modified workflow."""
        if node_id not in workflow:
            raise KeyError(f"Node '{node_id}' not found in workflow")
        workflow[node_id]["inputs"][field] = value
        return workflow

    @staticmethod
    def set_filename_prefix(workflow: dict, prefix: str) -> dict:
        """Set filename_prefix on all SaveImage/SaveGLB/Trellis2ExportGLB nodes in the workflow."""
        for node_id, node in workflow.items():
            class_type = node.get("class_type", "")
            inputs = node.get("inputs", {})
            if class_type in ("SaveGLB", "Trellis2ExportGLB") and "filename_prefix" in inputs:
                # Preserve subdirectory (e.g. "mesh/") but replace the name
                old = inputs["filename_prefix"]
                if "/" in old:
                    subdir = old.rsplit("/", 1)[0]
                    inputs["filename_prefix"] = f"{subdir}/{prefix}"
                else:
                    inputs["filename_prefix"] = prefix
            elif class_type == "SaveImage" and "filename_prefix" in inputs:
                old = inputs["filename_prefix"]
                # For PBR maps, keep the channel suffix (e.g. pbr_basecolor → prefix_basecolor)
                if old.startswith("pbr_"):
                    channel = old[4:]  # e.g. "basecolor", "normal", etc.
                    inputs["filename_prefix"] = f"{prefix}_{channel}"
                else:
                    inputs["filename_prefix"] = prefix
        return workflow

    def is_healthy(self) -> bool:
        """Check if the ComfyUI server is responding."""
        try:
            req = urllib.request.Request(f"{self.server}/system_stats")
            resp = urllib.request.urlopen(req, timeout=5)
            json.loads(resp.read())
            return True
        except Exception:
            return False


if __name__ == "__main__":
    server = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8188"
    client = ComfyUIClient(server)
    if client.is_healthy():
        print(f"ComfyUI at {server} is healthy")
    else:
        print(f"ComfyUI at {server} is not responding")
        sys.exit(1)
