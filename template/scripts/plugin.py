from pathlib import Path
from typing import Any

import base64
import ipaddress
import json
import makejinja
import re
import subprocess


# Return the filename of a path without the j2 extension
def basename(value: str) -> str:
    return Path(value).stem.removesuffix('.j2')


# Return the nth host in a CIDR range
def nthhost(value: str, query: int) -> str:
    network = ipaddress.ip_network(value, strict=False)
    return str(network[query])


# Return the age public or private key from age.key
def age_key(key_type: str, file_path: str = 'age.key') -> str:
    try:
        with open(file_path, 'r') as file:
            content = file.read()
            if key_type == 'public':
                match = re.search(r'public key: (\S+)', content)
                if match:
                    return match.group(1)
                raise ValueError(f"Public key not found in {file_path}")
            elif key_type == 'private':
                return content.strip()
            else:
                raise ValueError(f"Invalid key_type: {key_type}")
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {file_path}")
    except Exception as e:
        raise RuntimeError(f"Unexpected error while reading {file_path}: {e}")


# Return cloudflare tunnel ID from cloudflare-tunnel.json
def cloudflare_tunnel_id(file_path: str = 'cloudflare-tunnel.json') -> str:
    try:
        with open(file_path, 'r') as file:
            data = json.load(file)
            return data.get('TunnelID', '')
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {file_path}")
    except json.JSONDecodeError:
        raise ValueError(f"Invalid JSON in {file_path}")
    except Exception as e:
        raise RuntimeError(f"Unexpected error while reading {file_path}: {e}")


# Return cloudflare tunnel secret in TUNNEL_TOKEN format
def cloudflare_tunnel_secret(file_path: str = 'cloudflare-tunnel.json') -> str:
    try:
        with open(file_path, 'r') as file:
            data = json.load(file)
            account_tag = data.get('AccountTag', '')
            tunnel_id = data.get('TunnelID', '')
            tunnel_secret = data.get('TunnelSecret', '')

            if not all([account_tag, tunnel_id, tunnel_secret]):
                raise ValueError(f"Missing required fields in {file_path}")

            # Construct the tunnel token
            token_data = {
                "a": account_tag,
                "t": tunnel_id,
                "s": tunnel_secret
            }
            token_json = json.dumps(token_data, separators=(',', ':'))
            token_b64 = base64.b64encode(token_json.encode()).decode()
            return token_b64
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {file_path}")
    except (json.JSONDecodeError, ValueError) as e:
        raise ValueError(f"Error processing {file_path}: {e}")
    except Exception as e:
        raise RuntimeError(f"Unexpected error while reading {file_path}: {e}")


# Return the GitHub deploy key from github-deploy.key
def github_deploy_key(file_path: str = 'github-deploy.key') -> str:
    try:
        with open(file_path, 'r') as file:
            return file.read().strip()
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {file_path}")
    except Exception as e:
        raise RuntimeError(f"Unexpected error while reading {file_path}: {e}")


# Return the Flux / GitHub push token from github-push-token.txt
def github_push_token(file_path: str = 'github-push-token.txt') -> str:
    try:
        with open(file_path, 'r') as file:
            return file.read().strip()
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {file_path}")
    except Exception as e:
        raise RuntimeError(f"Unexpected error while reading {file_path}: {e}")


# Return a list of files in the capmox patches directory
def capmox_patches(value: str) -> list[str]:
    path = Path(f'template/config/capmox/patches/{value}')
    if not path.is_dir():
        return []
    return [str(f) for f in sorted(path.glob('*.yaml.j2')) if f.is_file()]


CONFIG_FILE = 'cluster.toml'
SCHEMA_FILE = 'template/resources/config.schema.cue'


# Run `cue export` to validate and apply schema defaults to the user's config
def cue_export() -> dict[str, Any]:
    try:
        result = subprocess.run(
            ['cue', 'export', CONFIG_FILE, SCHEMA_FILE, '--out', 'json'],
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"CUE validation failed:\n{e.stderr}")
    except FileNotFoundError:
        raise FileNotFoundError("cue command not found — install CUE from https://cuelang.org/")
    except json.JSONDecodeError:
        raise ValueError("CUE export did not return valid JSON")


class Plugin(makejinja.plugin.Plugin):
    def __init__(self, data: dict[str, Any]):
        self._data = data

    def data(self) -> makejinja.plugin.Data:
        data = cue_export()
        # Calculate default_gateway if not set
        network = data['network']
        # Support both node_cidr and lan_cidr
        cidr = network.get('node_cidr') or network.get('lan_cidr')
        if cidr and 'default_gateway' not in network:
            network['default_gateway'] = nthhost(cidr, 1)
        return data

    def filters(self) -> makejinja.plugin.Filters:
        return [
            basename,
            nthhost
        ]

    def functions(self) -> makejinja.plugin.Functions:
        return [
            age_key,
            cloudflare_tunnel_id,
            cloudflare_tunnel_secret,
            github_deploy_key,
            github_push_token,
            capmox_patches
        ]
