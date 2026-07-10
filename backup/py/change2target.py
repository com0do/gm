#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Dependency Analysis Tool for GMPS Project

Description:
    This tool collects and analyzes dependencies across lib/exec/pkg/img,
    and traces the impact of code changes to final container images.
    It provides caching mechanism to speed up repeated analysis.

Environment Variables:
    GMPS_TOP        - Path to IMS source directory (e.g., /path/to/ims)
    GMPS_BUILDMODE  - Build mode: debug | release
    GMPS_PLATFORM   - Target platform: rhlinux | solaris

Directory Structure:
    REPO_TOP        = dirname(GMPS_TOP)
    GMPS_DO         = ${GMPS_TOP}_do
    lib             = $REPO_TOP/$GMPS_DO/lib/$GMPS_PLATFORM/$GMPS_BUILDMODE
    exec            = $REPO_TOP/$GMPS_DO/exec/$GMPS_PLATFORM/$GMPS_BUILDMODE
    pkg             = $REPO_TOP/$GMPS_DO/pkg/$GMPS_PLATFORM/$GMPS_BUILDMODE
    img             = $REPO_TOP/$GMPS_DO/img

Data Format:
    lib/exec        - {file:/path/to/lib, deps:[]}
    pkg             - {pkg:IMSPhtppd, deps:[], rpms:[]}
    img             - {img:hss-hsscallp, deps:[], rpms:[]}

Usage:
    # Create dependency cache
    ./diff2target.py --create-cache <apsname>
    # Analyze dependency changes
    ./diff2target.py --target <target_name>

"""




import json
import os
import re
import sys
import time
import logging
import yaml
import hashlib
import tempfile
import subprocess
from pathlib import Path
from itertools import chain
from enum import Enum, unique
from collections import defaultdict
from dataclasses import dataclass, asdict, field
from json.encoder import encode_basestring_ascii
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Dict, List, Set, Tuple, Optional, Any, Union, Type
from git import Repo, InvalidGitRepositoryError, GitCommandError # type: ignore

sys.path.insert(0, str(Path(__file__).parent.parent / "4g_Containers" / "buildTools"))
from appDockerImageBuild import ( # type: ignore
    parse_version_info,
    parse_install_guide,
    parse_pod_descriptor,
)

REPO_TOP = os.getenv("REPO_TOP", "").rstrip("/")
GMPS_TOP = os.getenv("GMPS_TOP", "").rstrip("/")
GMPS_DO = os.getenv("GMPS_DO", "ims_do")
GMPS_PLATFORM = os.getenv("GMPS_PLATFORM", "rhlinux")
GMPS_BUILDMODE = os.getenv("GMPS_BUILDMODE", "debug")
if not REPO_TOP and GMPS_TOP:
    REPO_TOP = os.path.dirname(GMPS_TOP)

@dataclass(frozen=True)
class DepTypes:
    LIB: str = "lib"
    EXEC: str = "exec"
    PKG: str = "pkg"
    IMG: str = "img"
    JAVA: str = "java"

@unique
class CacheActions(str, Enum):
    NONE = "none"
    CREATE = "create"
    USE = "use"

@dataclass
class BuildSystemConfig:
    name: str                           # Build system name: gmps/make/cmake/imake
    pre_build_cmd: str = ""             # Pre-build command template
    build_cmd: str = ""                 # Build command template
    env_vars: Dict[str, str] = field(default_factory=dict)  # Environment variables to export
    env_overrides: str = ""             # Environment variable overrides
    target_pattern: str = ""            # Pattern to match target names

@dataclass
class TargetMapping:
    name: str
    target: str
    type: str = ""

@dataclass
class ImageConfig:
    docker_source_path: str
    base_image_url: str
    yum_repo_config: List[str]
    version_map: Dict[str, dict]

@unique
class ImageConfigType(str, Enum):
    CACHE = "cache"
    EXTERNAL = "external"

DEP_TYPES = DepTypes()

def get_logger(
    name: str = "", level: int = logging.INFO, logger: Optional[logging.Logger] = None
) -> logging.Logger:
    if not name:
        name = "dep"
    if logger is None:
        logger = logging.getLogger(name)
        logger.setLevel(level)

    if not logger.handlers:
        ch = logging.StreamHandler() # change to stdout with stream=sys.stdout
        ch.setLevel(level)
        formatter = logging.Formatter(
            "%(asctime)s [%(levelname)-7s] %(name)s: %(message)s"
        )
        ch.setFormatter(formatter)
        logger.addHandler(ch)
    return logger

logger = get_logger(name="cyrus", level=logging.INFO)
DEBUG = logger.debug
INFO = logger.info
WARN = logger.warning
ERROR = logger.error


def _check_environment():
    if not REPO_TOP:
        raise EnvironmentError(
            "GMPS_TOP or REPO_TOP is not set. "
            "Please set GMPS_TOP=/path/to/ims or REPO_TOP=/path/to/parent"
        )

def file_md5(file_path: Path) -> str:
    if not file_path.is_file():
        return ""
    hash_md5 = hashlib.md5()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_md5.update(chunk)
    return hash_md5.hexdigest()

class ShortListJSONEncoder(json.JSONEncoder):
    def __init__(self, *args, max_line_length=100, **kwargs):
        super().__init__(*args, **kwargs)
        self.max_line_length = max_line_length
        self._current_indent = 0

    def _is_short_list(self, o):
        if not isinstance(o, list):
            return False
        if not all(isinstance(item, (str, int, float, bool, type(None))) for item in o):
            return False
        encoded = self._encode_short_list(o)
        return len(encoded) <= self.max_line_length

    def _encode_short_list(self, o):
        """Encode a short list in compact format"""
        parts = []
        for item in o:
            if isinstance(item, str):
                parts.append(encode_basestring_ascii(item))
            elif item is None:
                parts.append('null')
            elif isinstance(item, bool):
                parts.append('true' if item else 'false')
            else:
                parts.append(str(item))
        return f"[{', '.join(parts)}]"

    def encode(self, o):
        self._current_indent = 0
        return self._encode_value(o)

    def _encode_value(self, o):
        """Encode any value with proper formatting"""
        if self._is_short_list(o):
            return self._encode_short_list(o)
        elif isinstance(o, dict):
            return self._encode_dict(o)
        elif isinstance(o, list):
            return self._encode_list(o)
        elif isinstance(o, str):
            return encode_basestring_ascii(o)
        elif o is None:
            return 'null'
        elif isinstance(o, bool):
            return 'true' if o else 'false'
        else:
            return json.dumps(o)

    def _get_indent(self):
        """Get current indentation string"""
        indent_size = int(self.indent) if self.indent else 2
        return ' ' * (indent_size * self._current_indent)

    def _encode_dict(self, o):
        """Recursively encode dict with short list formatting"""
        if not o:
            return '{}'
        items = []
        self._current_indent += 1
        indent_str = self._get_indent()
        for key, value in o.items():
            key_str = encode_basestring_ascii(key)
            value_str = self._encode_value(value)
            # Handle multi-line values
            if '\n' in value_str and not self._is_short_list(value):
                value_lines = value_str.split('\n')
                value_str = value_lines[0]
                for line in value_lines[1:]:
                    value_str += '\n' + indent_str + line
            items.append(f'{indent_str}{key_str}: {value_str}')
        self._current_indent -= 1
        return '{\n' + ',\n'.join(items) + '\n' + self._get_indent() + '}'

    def _encode_list(self, o):
        """Recursively encode list with short list formatting"""
        if not o:
            return '[]'
        if self._is_short_list(o):
            return self._encode_short_list(o)
        items = []
        self._current_indent += 1
        indent_str = self._get_indent()
        for item in o:
            item_str = self._encode_value(item)
            # Handle multi-line items
            if '\n' in item_str and not self._is_short_list(item):
                item_lines = item_str.split('\n')
                item_str = item_lines[0]
                for line in item_lines[1:]:
                    item_str += '\n' + indent_str + line
            items.append(indent_str + item_str)
        self._current_indent -= 1
        return '[\n' + ',\n'.join(items) + '\n' + self._get_indent() + ']'


class YumRepo:

    def __init__(self, ext_img: Optional[Dict[str, dict]] = None,
                 pod_descriptor: str = "", version_info: str = ""):
        self.rpminfo_script = Path(__file__).parent / "rpmInfo.sh"
        self.yum_input = Path(__file__).parent.parent / "4g_Containers" / "buildTools" / "buildInputs" / "4g.in"
        self._image_configs: Dict[str, ImageConfig] = {}

        if not self.rpminfo_script.exists():
            raise FileNotFoundError(f"rpmInfo.sh not found at {self.rpminfo_script}")
        if not self.yum_input.exists():
            raise FileNotFoundError(f"4g.in not found at {self.yum_input}")
        self.repo_templates = self._load_repo_templates()

        if ext_img:
            self.image_config_type = ImageConfigType.CACHE
            for image_name, extra in ext_img.items():
                version_string = extra.get('version_string', '')
                version_map = self._parse_version_string(version_string)
                self._image_configs[image_name] = ImageConfig(
                    docker_source_path = extra.get('docker_source_path', ''),
                    base_image_url = extra.get('base_image_url', ''),
                    yum_repo_config = list(version_map.keys()),
                    version_map = version_map
                )
        elif pod_descriptor and version_info:
            self.image_config_type = ImageConfigType.EXTERNAL
            with open(pod_descriptor, 'r') as f:
                ds_yaml_dict = yaml.safe_load(f)
            image_names = [
                CN['image']['name']
                for CN in ds_yaml_dict['POD descriptor']['POD'][0]['container']
            ]
            version_map = parse_version_info(version_info)
            for image_name in image_names:
                cfg = parse_pod_descriptor(pod_descriptor, image_name)
                self._image_configs[image_name] = ImageConfig(
                    docker_source_path = cfg.get('docker_source_path', ''),
                    base_image_url = cfg.get('base_image_url', ''),
                    yum_repo_config = cfg.get('yum_Repo_config') or [],
                    version_map = version_map
                )
        else:
            raise ValueError("Invalid image config type")

    def _parse_version_string(self, version_string: str) -> Dict[str, dict]:
        version_map = {}
        if not version_string:
            return version_map
        for entry in version_string.split(','):
            entry = entry.strip()
            if not entry:
                continue
            parts = entry.split('/')
            repo = parts[0]
            rel = parts[1] if len(parts) >= 2 else ''
            version = parts[2] if len(parts) >= 3 else ''
            version_map[repo] = {'rel': rel, 'version': version}
        return version_map

    def get_image_config(self, image_name: str) -> Optional[ImageConfig]:
        return self._image_configs.get(image_name)

    def _load_repo_templates(self) -> Dict[str, str]:
        repo_templates = {}
        with open(self.yum_input, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2:
                    tag, url_template = parts
                    repo_templates[tag] = url_template
        return repo_templates

    def _generate_yum_repo(self, yum_repo_config: List[str], version_map: Dict[str, dict]) -> str:
        priority = 1
        repo_content = []
        for tag in yum_repo_config:
            if tag not in self.repo_templates:
                WARN(f"Repo tag '{tag}' not found in 4g.in")
                continue

            url = self.repo_templates[tag]
            needs_substitution = '##REL##' in url or '##VERSION##' in url
            if needs_substitution:
                if tag not in version_map:
                    WARN(f"Version not found for tag '{tag}', but repo URL requires version substitution")
                    continue
                ver_info = version_map[tag]
                url = url.replace('##REL##', ver_info['rel'])
                url = url.replace('##VERSION##', ver_info['version'])
                if ver_info.get('override'):
                    try:
                        result = subprocess.run(
                            ['sed', '-e', ver_info['override']],
                            input=url,
                            capture_output=True,
                            text=True,
                            check=True
                        )
                        url = result.stdout.strip()
                    except subprocess.CalledProcessError:
                        ERROR(f"Failed to apply override for {tag}: {ver_info['override']}")
                        continue

            repo_entry = f"[{tag}]\nname={tag}\nbaseurl={url}\ngpgcheck=0\nenabled=1\npriority={priority}\n"
            repo_content.append(repo_entry)
            priority += 1

        return '\n'.join(repo_content)

    def query_rpm_versions(self, image_name: str, rpm_list: List[str], arch: Optional[str] = None) -> Dict[str, Any]:
        if not rpm_list:
            return {}
        if arch and arch not in ['x86_64', 'i686', 'noarch']:
            WARN(f"Invalid arch '{arch}' specified")
            return {}

        if image_name not in self._image_configs:
            WARN(f"Image '{image_name}' not found in cache, skipping RPM version check")
            return {}

        cfg = self._image_configs[image_name]
        base_image = cfg.base_image_url
        yum_repo_config = cfg.yum_repo_config
        if not yum_repo_config and not base_image:
            WARN(f"{image_name} not found in cache, skipping RPM version check")
            return {}

        yum_repo_path = None
        if yum_repo_config:
            yum_repo_content = self._generate_yum_repo(yum_repo_config, cfg.version_map)
            yum_repo_path = f"/tmp/{image_name}.repo"
            with open(yum_repo_path, 'w') as f:
                f.write(yum_repo_content)

        extra_repo_paths = []
        if image_name in ['hss-hlrcallp', 'hss-ss7stack']:
            plugins_dir = Path(__file__).parent.parent / '3g_Containers/plugins'
            csf_rocky_repo = plugins_dir / 'csf-rocky-artifactory.repo'
            csf_epel_repo = plugins_dir / 'csf-epel-artifactory.repo'
            if csf_rocky_repo.exists():
                extra_repo_paths.append(str(csf_rocky_repo))
            if csf_epel_repo.exists():
                extra_repo_paths.append(str(csf_epel_repo))

        try:
            cmd = [str(self.rpminfo_script), '--image', image_name]
            if yum_repo_path:
                cmd.extend(['--yum', yum_repo_path])
            for extra_repo in extra_repo_paths:
                cmd.extend(['--extra-repo', extra_repo])
            if base_image:
                cmd.extend(['--base_image', base_image])
            if arch:
                cmd.extend(['--arch', arch])
            cmd.extend(rpm_list)

            INFO(f"[{image_name:<17s}]: {' '.join(cmd)}")
            DEBUG(f"[{image_name:<17s}] Running rpmInfo.sh with {len(rpm_list)} RPMs...")
            start_time = time.time()
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=False
            )
            elapsed = time.time() - start_time
            DEBUG(f"[{image_name:<17s}] rpmInfo.sh completed in {elapsed:.2f}s")

            if result.returncode != 0:
                ERROR(f"rpmInfo.sh failed for {image_name}: {result.stderr}")
                return {}

            rpm_info = {}
            for line in result.stdout.strip().split('\n'):
                if not line:
                    continue
                parts = line.split()
                if parts[1] == 'NOT_FOUND':
                    rpm_info[parts[0]] = 'NOT_FOUND'
                    ERROR(f"[{image_name:<17s}] RPM '{parts[0]}' not found")
                elif len(parts) == 4:
                    name, version, release, arch_type = parts
                    rpm_info[name] = [version, release, arch_type]

            return rpm_info

        finally:
            if yum_repo_path:
                pass
                # Path(yum_repo_path).unlink(missing_ok=True)

class DependencyDAG:
    def __init__(self, cache_action: CacheActions = CacheActions.NONE, max_workers: int = 4):
        self.type_map: Dict[str, str] = {}
        self.pod_descriptor = ""
        self.version_info = ""
        self.version = ""
        self.digest = ""
        self.repo = set()
        self._max_workers = max_workers
        self._yum_repo = None
        self._no_repo = ["ims_do"]

        # use dict to simulate set for faster lookup while ensuring write order
        self.mid_lib: Dict[str, Dict[str, None]] = defaultdict(dict)
        self.mid_oth: Dict[str, Dict[str, None]] = defaultdict(dict)
        self.rpm_oth: Dict[str, Dict[str, Union[None, List[str]]]] = defaultdict(dict)

        # auxiliary structures for DAG traversal and digest calculate
        self.core_dag: Dict[str, Set[str]] = defaultdict(set)
        self.dir_oth: Dict[str, Set[str]] = defaultdict(set)
        self.ext_img: Dict[str, Dict[str, Any]] = defaultdict(dict)
        self.digest_ignore: Dict[str, Dict[str, str]] = defaultdict(dict)

        # Cache for git repositories and their ignore patterns
        self._repo_cache: Dict[str, Repo] = {}
        self._repo_ignored: Dict[str, Set[str]] = defaultdict(set)
        self._repo_checked: Dict[str, Set[str]] = defaultdict(set)

        _check_environment()
        self._cache_action = cache_action
        self._use_cache = cache_action == CacheActions.USE
        self._pos_prefix = f"{REPO_TOP}/{GMPS_DO}"
        self._pos_prefix_cache = f"{REPO_TOP}/ims_admin/production/dep"
        self._dep_path_lib = Path()
        self._dep_path_exec = Path()
        self._dep_path_pkg = Path()
        self._dep_path_img = Path()
        self._dep_path_java = Path()
        self._check_path(cache_action)

    def __call__(self, version: str):
        self.build_dag()
        if self._cache_action == CacheActions.CREATE:
            self.create_cache(version)
        return self

    def _check_path(self, cache_action: CacheActions) -> bool:
        ims_do_lib = Path(self._pos_prefix, DepTypes.LIB, GMPS_PLATFORM, GMPS_BUILDMODE)
        ims_do_exe = Path(self._pos_prefix, DepTypes.EXEC, GMPS_PLATFORM, GMPS_BUILDMODE)
        ims_do_pkg = Path(self._pos_prefix, DepTypes.PKG, GMPS_PLATFORM, GMPS_BUILDMODE)
        ims_do_img = Path(self._pos_prefix, DepTypes.IMG)
        ims_do_java = Path(self._pos_prefix, DepTypes.JAVA)
        cache_lib = Path(self._pos_prefix_cache, DepTypes.LIB)
        cache_exe = Path(self._pos_prefix_cache, DepTypes.EXEC)
        cache_pkg = Path(self._pos_prefix_cache, DepTypes.PKG)
        cache_img = Path(self._pos_prefix_cache, DepTypes.IMG)
        cache_java = Path(self._pos_prefix_cache, DepTypes.JAVA)

        if cache_action != CacheActions.USE:
            ims_do_lib.mkdir(parents=True, exist_ok=True)
            ims_do_exe.mkdir(parents=True, exist_ok=True)
            ims_do_pkg.mkdir(parents=True, exist_ok=True)
            ims_do_img.mkdir(parents=True, exist_ok=True)
            ims_do_java.mkdir(parents=True, exist_ok=True)
            if not any(ims_do_lib.glob("lib*.dep.json")):
                raise FileNotFoundError(f"No lib dep files found in {ims_do_lib}")
            if not any(ims_do_exe.glob("*.dep.json")):
                raise FileNotFoundError(f"No exec dep files found in {ims_do_exe}")
            if not any(ims_do_pkg.glob("IMS*.dep.json")):
                raise FileNotFoundError(f"No pkg dep files found in {ims_do_pkg}")
            if not any(ims_do_img.glob("*.dep.json")):
                raise FileNotFoundError(f"No img dep files found in {ims_do_img}")
            self._dep_path_lib = ims_do_lib
            self._dep_path_exec = ims_do_exe
            self._dep_path_pkg = ims_do_pkg
            self._dep_path_img = ims_do_img
            self._dep_path_java = ims_do_java
        else:
            Path(self._pos_prefix_cache).mkdir(parents=True, exist_ok=True)
            Path(self._pos_prefix_cache, "version").touch(exist_ok=True)
            cache_lib.mkdir(parents=True, exist_ok=True)
            cache_exe.mkdir(parents=True, exist_ok=True)
            cache_pkg.mkdir(parents=True, exist_ok=True)
            cache_img.mkdir(parents=True, exist_ok=True)
            cache_java.mkdir(parents=True, exist_ok=True)
            if self._is_cache_valid() is False:
                raise FileNotFoundError("Cache is invalid, please regenerate.")
            if not any(cache_lib.glob("lib*.dep.json")):
                raise FileNotFoundError(f"No lib dep files found in {cache_lib}")
            if not any(cache_exe.glob("*.dep.json")):
                raise FileNotFoundError(f"No exec dep files found in {cache_exe}")
            if not any(cache_pkg.glob("IMS*.dep.json")):
                raise FileNotFoundError(f"No pkg dep files found in {cache_pkg}")
            if not any(cache_img.glob("*.dep.json")):
                raise FileNotFoundError(f"No img dep files found in {cache_img}")
            self._dep_path_lib = cache_lib
            self._dep_path_exec = cache_exe
            self._dep_path_pkg = cache_pkg
            self._dep_path_img = cache_img
            self._dep_path_java = cache_java
        return True

    def _load_repo(self, repo: str) -> Optional[Repo]:
        if repo in self._repo_cache:
            return self._repo_cache[repo]
        try:
            repo_obj = Repo(f"{REPO_TOP}/{repo}")
            self._repo_cache[repo] = repo_obj
            return repo_obj
        except (InvalidGitRepositoryError, Exception) as e:
            WARN(f"Failed to load repo {repo}: {e}")
            return None

    def _check_ignore_batch(self, repo: str, files: List[str]) -> Set[str]:
        if not files:
            return set()

        unchecked = [f for f in files if f not in self._repo_checked[repo]]
        if not unchecked:
            return self._repo_ignored[repo] & set(files)
        repo_obj = self._load_repo(repo)
        if repo_obj is None:
            return set()

        ignored = set()
        DEBUG(f"Batch checking {len(unchecked)} files for git ignore in repo: {repo} (skipped {len(files) - len(unchecked)} already checked)")
        try:
            # Use git check-ignore with multiple files at once
            # Split into smaller batches to avoid command line length limits
            batch_size = 100
            for i in range(0, len(unchecked), batch_size):
                batch = unchecked[i:i+batch_size]
                try:
                    result = repo_obj.git.check_ignore(*batch)
                    if result:
                        ignored.update(set(result.strip().split('\n')))
                except GitCommandError as e:
                    # Exit code 1 means no files are ignored, which is normal
                    # Exit code 128 often means symlink issues, skip silently
                    if e.status not in (1, 128):
                        WARN(f"Git check-ignore failed with exit code {e.status}: {e}")
            if ignored:
                INFO(f"Found {repo} ignored files: {ignored}")
            self._repo_checked[repo].update(unchecked)
        except Exception as e:
            WARN(f"Error checking ignore for repo {repo}: {e}")
        return ignored

    def _check_ignore(self, repo: str, file: str) -> bool:
        if repo in self._repo_ignored:
            ignored_files = self._repo_ignored[repo]
            if file in ignored_files:
                file_path = Path(REPO_TOP, repo, file)
                self.digest_ignore[repo][file] = file_md5(file_path)
                INFO(f"File {file} is ignored in repo {repo}")
                return True
        return False

    def _cache_digest(self):
        cache_files = []
        cache_prefix = Path(self._pos_prefix_cache)
        for type in [DepTypes.LIB, DepTypes.EXEC, DepTypes.PKG, DepTypes.IMG, DepTypes.JAVA]:
            path = cache_prefix / type
            cache_files.extend(path.glob("*.dep.json"))
        cache_files.sort(key=lambda x: x.relative_to(cache_prefix).as_posix())

        hash_md5 = hashlib.md5()
        for file in cache_files:
            digest_value = file_md5(file)
            hash_md5.update(digest_value.encode('utf-8'))
        return hash_md5.hexdigest()

    def _is_cache_valid(self) -> bool:
        # aps_file = Path(REPO_TOP, "ims_admin", "production", "config", "rhlinux", "apsname")
        # aps = aps_file.read_text(encoding='utf-8').strip() if aps_file.is_file() else ""
        version_file = Path(self._pos_prefix_cache, "version")

        if not version_file.is_file():
            return False
        self.version, self.digest = version_file.read_text(encoding='utf-8').strip().split('\n')[:2]
        if self.digest != self._cache_digest():
            ERROR(f"{self.version} cache digest mismatch, expected {self.digest}")
            return False
        else:
            INFO(f"use cache version {self.version} with digest {self.digest[:16]}")
            return True

    def is_internal_rpm(self, rpm):
        if isinstance(rpm, list) and len(rpm) >= 1:
            return rpm[0].startswith("IMS")
        elif isinstance(rpm, str):
            return rpm.startswith("IMS")
        return False

    def _is_system_rpm(self, rpm):
        rpm_name = ""
        exclude_prefix = ["IMS", "SMAW", "INT"]
        if isinstance(rpm, list) and len(rpm) >= 1:
            rpm_name = rpm[0]
        elif isinstance(rpm, str):
            rpm_name = rpm
        return not any(rpm_name.startswith(prefix) for prefix in exclude_prefix)

    def _parse_json_file(self, file_path: str) -> Tuple[str, dict]:
        prefix = self._pos_prefix if not self._use_cache else self._pos_prefix_cache
        type = file_path.removeprefix(prefix).split("/",2)[1]
        try:
            with open(file_path, 'r') as f:
                data = json.load(f)
            if not isinstance(data, dict):
                raise ValueError("dep file format error")
            if type in [DepTypes.LIB, DepTypes.EXEC, DepTypes.JAVA]:
                if not data.get("file") or not data.get("deps"):
                    raise ValueError("lib/exec/java dep file format error")
            elif type == DepTypes.PKG:
                if not data.get("pkg") or not data.get("deps"):
                    raise ValueError("pkg dep file format error")
            elif type == DepTypes.IMG:
                if not data.get("img") or not data.get("deps"):
                    raise ValueError("img dep file format error")
            return type, data
        except Exception as e:
            ERROR(f"Parse file {file_path} failed: {e}")
            return "unknown", {}

    def create_cache(self, version: str):
        cache_base = Path(self._pos_prefix_cache)
        cache_lib_dir = cache_base / DepTypes.LIB
        cache_exec_dir = cache_base / DepTypes.EXEC
        cache_pkg_dir = cache_base / DepTypes.PKG
        cache_img_dir = cache_base / DepTypes.IMG
        cache_java_dir = cache_base / DepTypes.JAVA

        if not version:
            raise ValueError("Version string is required to create cache")
        for cache_dir in [cache_lib_dir, cache_exec_dir, cache_pkg_dir, cache_img_dir, cache_java_dir]:
            cache_dir.mkdir(parents=True, exist_ok=True)

        version_file = cache_base / "version"
        version_file.write_text(version, encoding='utf-8')
        aps_file = Path(REPO_TOP, "ims_admin", "production", "config", "rhlinux", "apsname")
        if aps_file.is_file():
            aps_version = aps_file.read_text(encoding='utf-8').strip()
            WARN(f"Apsname version {aps_version}, cache version {version}")
        else:
            raise FileNotFoundError("apsname file not found")

        INFO(f"Creating cache at {cache_base}")
        for file, deps in self.mid_lib.items():
            file_type = self.type_map.get(file, "")
            target = Path(file).name.split(".",1)[0]
            if file_type == DepTypes.LIB:
                cache_file = cache_lib_dir / f"{target}.dep.json"
                cache_data = {
                    "file": file,
                    "deps": list(deps.keys())
                }
                with open(cache_file, 'w') as f:
                    json.dump(cache_data, f, indent=2)
            elif file_type == DepTypes.EXEC:
                cache_file = cache_exec_dir / f"{target}.dep.json"
                cache_data = {
                    "file": file,
                    "deps": list(deps.keys())
                }
                with open(cache_file, 'w') as f:
                    json.dump(cache_data, f, indent=2)
            elif file_type == DepTypes.JAVA:
                cache_file = cache_java_dir / f"{target}.dep.json"
                cache_data = {
                    "file": file,
                    "deps": list(deps.keys())
                }
                with open(cache_file, 'w') as f:
                    json.dump(cache_data, f, indent=2)

        for file, deps in self.mid_oth.items():
            file_type = self.type_map.get(file, "")
            target = Path(file).name.split(".",1)[0]
            if file_type == DepTypes.PKG:
                cache_file = cache_pkg_dir / f"{target}.dep.json"
                rpms = []
                for rpm_name, rpm_data in self.rpm_oth[file].items():
                    if rpm_data is None:
                        rpms.append(rpm_name)
                    else:
                        rpms.append([rpm_name] + rpm_data)
                cache_data = {
                    "pkg": file,
                    "rpms": rpms,
                    "deps": list(deps.keys())
                }
                with open(cache_file, 'w') as f:
                    json.dump(cache_data, f, indent=2)
            elif file_type == DepTypes.IMG:
                cache_file = cache_img_dir / f"{target}.dep.json"
                rpms = []
                for rpm_name, rpm_data in self.rpm_oth[file].items():
                    if rpm_data is None:
                        rpms.append(rpm_name)
                    else:
                        rpms.append([rpm_name] + rpm_data)
                cache_data = {
                    "img": file,
                    "rpms": rpms,
                    "deps": list(deps.keys()),
                    "extra": self.ext_img[file]
                }
                with open(cache_file, 'w') as f:
                    # json.dump(cache_data, f, indent=2)
                    f.write(json.dumps(cache_data, cls=ShortListJSONEncoder, indent=2, max_line_length=100))

        digest_file = cache_base / "digest.dep.json"
        if self.digest_ignore:
            with open(digest_file, 'w') as f:
                json.dump(self.digest_ignore, f, indent=2)
            INFO(f"Update ignore files digest with {len(self.digest_ignore)} repos")
        elif digest_file.exists():
                digest_file.unlink()

        summary_hash = self._cache_digest()
        version_content = f"{version}\n{summary_hash}\n"
        version_file.write_text(version_content, encoding='utf-8')

        lib_count = sum(1 for t in self.type_map.values() if t == DepTypes.LIB)
        exec_count = sum(1 for t in self.type_map.values() if t == DepTypes.EXEC)
        pkg_count = sum(1 for t in self.type_map.values() if t == DepTypes.PKG)
        img_count = sum(1 for t in self.type_map.values() if t == DepTypes.IMG)
        java_count = sum(1 for t in self.type_map.values() if t == DepTypes.JAVA)
        INFO(f"Cache {version}:{summary_hash[:16]} created: {lib_count} libs, {exec_count} execs, {pkg_count} pkgs, {img_count} imgs, {java_count} javas")

    def load_dep(self, file_type, data):
        ims_tool = f"{REPO_TOP}/ims_tools/"
        file = data.get("file", data.get("pkg", data.get("img", "")))
        deps = data.get("deps", [])
        rpms = data.get("rpms", [])
        extra = data.get("extra", {})
        file = file.removeprefix(f"{REPO_TOP}/")
        self.type_map[file] = file_type
        repo_files_to_check = defaultdict(list)

        if file_type in [DepTypes.LIB, DepTypes.EXEC, DepTypes.JAVA]:
            for dep in deps:
                is_repo = False
                is_mid = False
                if not dep.startswith("/"):
                    continue
                if dep.startswith(str(self._dep_path_lib)) or dep.startswith(str(self._dep_path_java)):
                    is_mid = True
                elif dep.startswith(ims_tool):
                    dep = Path(dep).resolve().as_posix()
                elif dep.startswith(REPO_TOP):
                    repo, dep_file = dep.removeprefix(f"{REPO_TOP}/").split("/",1)
                    if repo not in self._no_repo:
                        is_repo = True
                        repo_files_to_check[repo].append(dep_file)

                dep = dep.removeprefix(f"{REPO_TOP}/")
                if is_repo:
                    self.repo.add(dep.split("/",1)[0])
                if is_mid:
                    self.core_dag[dep].add(file)
                self.mid_lib[file][dep] = None

        elif file_type in [DepTypes.PKG, DepTypes.IMG]:
            for dep in deps:
                is_repo = False
                is_mid = False
                is_dir = False
                if not dep.startswith("/"):
                    continue
                # Path(dep).is_dir() is time consuming but more compatiable,
                # dep.endswith("/") is more efficient but less reliable
                elif Path(dep).is_dir():
                    is_dir = True
                if dep.startswith(str(self._dep_path_exec)) or dep.startswith(str(self._dep_path_lib)) or dep.startswith(str(self._dep_path_java)):
                    is_mid = True
                elif dep.startswith(ims_tool):
                    dep = Path(dep).resolve().as_posix()
                elif dep.startswith(REPO_TOP):
                    repo, dep_file = dep.removeprefix(f"{REPO_TOP}/").split("/",1)
                    if repo not in self._no_repo:
                        is_repo = True
                        repo_files_to_check[repo].append(dep_file)

                dep = dep.removeprefix(f"{REPO_TOP}/")
                if is_repo:
                    self.repo.add(dep.split("/",1)[0])
                if is_mid:
                    self.core_dag[dep].add(file)
                if is_dir:
                    self.dir_oth[file].add(dep)
                self.mid_oth[file][dep] = None

            for rpm in rpms:
                if isinstance(rpm, list) and len(rpm) >= 4:
                    self.rpm_oth[file][rpm[0]] = [rpm[1], rpm[2], rpm[3]]
                    if self.is_internal_rpm(rpm):
                        self.core_dag[rpm[0]].add(file)
                elif isinstance(rpm, str):
                    self.rpm_oth[file][rpm] = None
                    if self.is_internal_rpm(rpm):
                        self.core_dag[rpm].add(file)

            for ext in extra:
                self.ext_img[file][ext] = extra[ext]

        for repo, files in repo_files_to_check.items():
            if not files:
                continue
            ignored = self._check_ignore_batch(repo, files)
            if not ignored:
                continue
            for ignored_file in ignored:
                file_path = Path(REPO_TOP, repo, ignored_file)
                self.digest_ignore[repo][ignored_file] = file_md5(file_path)
            self._repo_ignored[repo].update(ignored)

    def load_dep_cache(self, file_type, data):
        file = data.get("file", data.get("pkg", data.get("img", "")))
        deps = data.get("deps", [])
        rpms = data.get("rpms", [])
        extra = data.get("extra", {})
        self.type_map[file] = file_type
        if file_type in [DepTypes.LIB, DepTypes.EXEC, DepTypes.JAVA]:
            for dep in deps:
                is_repo = False
                is_mid = False
                if dep.startswith(GMPS_DO):
                    is_mid = True
                elif not dep.startswith("/"):
                    if dep.split("/",1)[0] not in self._no_repo:
                        is_repo = True

                if is_repo:
                    self.repo.add(dep.split("/",1)[0])
                if is_mid:
                    self.core_dag[dep].add(file)
                self.mid_lib[file][dep] = None
        elif file_type in [DepTypes.PKG, DepTypes.IMG]:
            for dep in deps:
                is_repo = False
                is_mid = False
                is_dir = False
                if dep.startswith(GMPS_DO):
                    is_mid = True
                if not dep.startswith("/"):
                    if dep.split("/",1)[0] not in self._no_repo:
                        is_repo = True
                    if Path(REPO_TOP, dep).is_dir():
                        is_dir = True
                else:
                    if Path(dep).is_dir():
                        is_dir = True

                if is_repo:
                    self.repo.add(dep.split("/",1)[0])
                if is_mid:
                    self.core_dag[dep].add(file)
                if is_dir:
                    self.dir_oth[file].add(dep)
                self.mid_oth[file][dep] = None
            for rpm in rpms:
                if isinstance(rpm, list) and len(rpm) >= 4:
                    self.rpm_oth[file][rpm[0]] = [rpm[1], rpm[2], rpm[3]]
                    if self.is_internal_rpm(rpm):
                        self.core_dag[rpm[0]].add(file)
                elif isinstance(rpm, str):
                    self.rpm_oth[file][rpm] = None
                    if self.is_internal_rpm(rpm):
                        self.core_dag[rpm].add(file)

            for ext in extra:
                self.ext_img[file][ext] = extra[ext]

    def build_dag(self, limit_files: int = 0) -> None:
        all_files = list(chain(self._dep_path_lib.glob("lib*.dep.json"),
                               self._dep_path_exec.glob("*.dep.json"),
                               self._dep_path_pkg.glob("IMS*.dep.json"),
                               self._dep_path_img.glob("*.dep.json"),
                               self._dep_path_java.glob("*.dep.json")))

        if limit_files > 0:
            all_files = all_files[:limit_files]
            INFO(f"DEBUG MODE: Processing only first {len(all_files)} files")
        with ThreadPoolExecutor(max_workers=self._max_workers) as executor:
            future_to_file = {
                executor.submit(self._parse_json_file, str(file)): file
                for file in all_files
            }
            for future in as_completed(future_to_file):
                file_path = future_to_file[future]
                try:
                    file_type, data = future.result()
                    if not self._use_cache:
                        self.load_dep(file_type, data)
                    else:
                        self.load_dep_cache(file_type, data)

                    DEBUG(f"handling {file_type} {file_path} with {len(data.get('deps', []))} dependencies")
                except Exception as e:
                    ERROR(f"handling {file_path} error: {e}")
        for ignored_repo,ignored_files in self.digest_ignore.items():
            ERROR(f"Found {ignored_repo} ignored files {ignored_files.keys()}")

    def find_mid(self, leaf: str) -> Set[str]:
        affected = set()
        is_src = Path(leaf).suffix.lower() in {
                ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hh", ".hxx"}
        mid = self.mid_lib if is_src else self.mid_oth
        if leaf in self.mid_lib or leaf in self.mid_oth:
            return {leaf}
        if "/" not in leaf:
            for k, leaves in self.rpm_oth.items():
                if leaf in leaves:
                    affected.add(k)
        else:
            for k, leaves in mid.items():
                if leaf in leaves:
                    affected.add(k)

        if not affected and "/" in leaf:
            for k, dirs in self.dir_oth.items():
                for dir_path in dirs:
                    if leaf.startswith(dir_path + "/"):
                        affected.add(k)
                        break

        return affected

    def affected_images(self, leaf: str):
        visited = set()
        libs = set()
        exec = set()
        pkgs = set()
        images = set()
        mids = self.find_mid(leaf)
        def dfs_core(node: str):
            if node in visited:
                return
            visited.add(node)
            if self.type_map[node] == DepTypes.IMG:
                images.add(node)
                return
            elif self.type_map[node] == DepTypes.PKG:
                pkgs.add(node)
            elif self.type_map[node] == DepTypes.EXEC:
                exec.add(node)
            elif self.type_map[node] in [DepTypes.LIB, DepTypes.JAVA]:
                libs.add(node)
            for parent in self.core_dag.get(node, set()):
                dfs_core(parent)
        for mid in mids:
            dfs_core(mid)
        return images, pkgs, exec, libs

    def affected_images_rpm(self, images: set):
        yum_repo = self._yum_repo_inst()
        if yum_repo is None:
            WARN("YumRepo not initialized, skipping RPM update check")
            return images
        images_to_check = []
        images_list = []
        for img, rpms in self.rpm_oth.items():
            if self.type_map[img] != DepTypes.IMG or img in images:
                continue
            rpm_names = []
            for rpm_name, rpm_info in rpms.items():
                if isinstance(rpm_info, list) and len(rpm_info) >= 3:
                    rpm_names.append(rpm_name)
            if not rpm_names:
                continue
            images_to_check.append((img, rpm_names))
            images_list.append(img)

        if not images_to_check:
            return images
        INFO(f"Starting parallel RPM update check for: {' '.join(images_list)}")
        def check_image_rpms(img_data):
            img, rpm_names = img_data
            DEBUG(f"[{img}] Checking {len(rpm_names)} RPMs...")
            start_time = time.time()
            repo_rpm_info = yum_repo.query_rpm_versions(img, rpm_names)
            elapsed = time.time() - start_time
            INFO(f"[{img:<17s}] Query completed in {elapsed:.2f}s, got {len(repo_rpm_info)} results")
            if self._check_rpm_updates(img, repo_rpm_info):
                return img
            return None

        updated_images = []
        with ThreadPoolExecutor(max_workers=len(images_to_check)) as executor:
            future_to_img = {executor.submit(check_image_rpms, img_data): img_data[0] for img_data in images_to_check}
            for future in as_completed(future_to_img):
                try:
                    result = future.result()
                    if result:
                        updated_images.append(result)
                except Exception as e:
                    img_file = future_to_img[future]
                    ERROR(f"Error checking RPMs for {img_file}: {e}")

        images.update(updated_images)
        INFO(f"RPM update check completed: checked {len(images_to_check)} images, found {len(updated_images)} with updates, {len(images)} total affected")
        return images

    def affected_images_all(self, change_list: list[str]):
        libs = set()
        exec = set()
        pkgs = set()
        images = set()

        for change in change_list:
            img_set, pkg_set, exe_set, lib_set = self.affected_images(change)
            images.update(img_set)
            pkgs.update(pkg_set)
            exec.update(exe_set)
            libs.update(lib_set)

        return self.affected_images_rpm(images), pkgs, exec, libs

    def _yum_repo_inst(self) -> Optional[YumRepo]:
        if self._yum_repo is None:
            if self.ext_img:
                self._yum_repo = YumRepo(ext_img=self.ext_img)
            elif self.pod_descriptor and self.version_info:
                self._yum_repo = YumRepo(pod_descriptor=self.pod_descriptor, version_info=self.version_info)
            else:
                return None
        return self._yum_repo

    def _check_rpm_updates(self, img_file: str, repo_rpm_info: Dict[str, Union[str, List[str]]]) -> bool:
        has_update = False
        for rpm_name, cache_rpm_info in self.rpm_oth[img_file].items():
            if cache_rpm_info is None or rpm_name not in repo_rpm_info:
                continue
            if not isinstance(cache_rpm_info, list) or len(cache_rpm_info) < 3:
                continue
            repo_info = repo_rpm_info[rpm_name]
            if repo_info == 'NOT_FOUND':
                cache_ver, cache_rel, cache_arch = cache_rpm_info[0], cache_rpm_info[1], cache_rpm_info[2]
                WARN(f"RPM not found in repo for {img_file}: {rpm_name} "
                     f"(cache has {cache_ver}-{cache_rel}, but not found in current repos)")
                continue
            if not isinstance(repo_info, list) or len(repo_info) < 3:
                continue
            if not self._is_system_rpm(rpm_name):
                continue

            cache_ver, cache_rel, cache_arch = cache_rpm_info[0], cache_rpm_info[1], cache_rpm_info[2]
            repo_ver, repo_rel, repo_arch = repo_info[0], repo_info[1], repo_info[2]

            if cache_ver != repo_ver or cache_rel != repo_rel:
                INFO(f"[{img_file:<17s}] RPM update detected in {img_file}: {rpm_name} "
                     f"{cache_ver}-{cache_rel} -> {repo_ver}-{repo_rel}")
                has_update = True
                break

        return has_update

    def lock_rpm_info(self, rpm_input: Optional[str] = None, output: str = "") -> Dict[str, Dict[str, List[str]]]:
        rpm_override = {}
        if rpm_input:
            rpm_path = Path(rpm_input)
            if not rpm_path.is_file():
                raise FileNotFoundError(f"RPM input file {rpm_input} does not exist")
            for line in rpm_path.read_text(encoding='utf-8').splitlines():
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split()
                if len(parts) >= 4:
                    rpm_name, version, release, arch = parts[0], parts[1], parts[2], parts[3]
                    rpm_override[rpm_name] = [version, release, arch]
            INFO(f"Loaded {len(rpm_override)} RPM override entries from {rpm_input}")

        rpm_lock = defaultdict(dict)
        for img_file, rpms in self.rpm_oth.items():
            if self.type_map.get(img_file) != DepTypes.IMG:
                continue
            for rpm_name, rpm_info in rpms.items():
                if rpm_name in rpm_override:
                    rpm_info = rpm_override[rpm_name]
                if isinstance(rpm_info, list) and len(rpm_info) >= 3:
                    rpm_lock[img_file][rpm_name] = rpm_info
        output_file = Path(output).mkdir(parents=True, exist_ok=True)
        for image_name, rpms in rpm_lock.items():
            file = Path(output, f"{image_name}.rpm.info")
            with open(file, 'w') as f:
                for rpm_name, rpm_info in sorted(rpms.items()):
                    f.write(f"{rpm_name} {rpm_info[0]} {rpm_info[1]} {rpm_info[2]}\n")
            INFO(f"RPM lock info written to {file}")
        return rpm_lock

class TargetManager(DependencyDAG):
    """
    Manager for build system integration and dependency completeness checking.
    """
    DEFAULT_BUILD_SYSTEMS = {
        "gmps": BuildSystemConfig(
            name="gmps",
            pre_build_cmd="gm {TARGET} -gf -j -clean",
            build_cmd="gm {TARGET} -gf -j",
            env_vars={
                "GMPS_PROJECT": "ims",
                "GMPS_PLATFORM": "rhlinux",
                "GMPS_BUILDMODE": "debug",
                "DEP_TREE": "yes"
            },
            env_overrides="gmps_env.sh",
        ),
    }

    RPM_TO_GMPS_PATTERNS = [
        (r"^(?:IMSP|INTP|SMAW).+$", "pkg"),
        (r"^lib.+$", "lib"),
        (r"^[A-Z].+$", "exec"),
    ]

    def __init__(self, cache_action: CacheActions = CacheActions.USE, new_target: bool = True):
        super().__init__(cache_action=cache_action)

        self.build_system = "gmps"
        self.top_target = "ProdHssdHB"  # ProdHssd++pkg
        self.pkg_target = "ProdHssdnopkgs"
        self._build_configs = dict(self.DEFAULT_BUILD_SYSTEMS)
        self.new_target = new_target

        self._ims_admin_path = Path(REPO_TOP) / "ims_admin"
        self._gms_deps_tree = self._ims_admin_path / "gmps" / "bin" / "gms_deps_tree"
        self._tm_version_file = self._ims_admin_path / "production" / "dep" / "version"
        self._tm_dep_cache_path = self._ims_admin_path / "production" / "dep"

        self._gmps_targets: Dict[str, List[str]] = {}
        self._rpm_mapping_cache: Dict[str, TargetMapping] = {}

        if not (self._gms_deps_tree.exists() and self._tm_version_file.exists()
                and self._tm_dep_cache_path.exists()):
            raise FileNotFoundError("gms_deps_tree, version file, or dep cache path not found")

    def __call__(self, version: str):
        super().__call__(version)
        self.check_dependency_completeness(self.new_target)
        return self

    def rpm_to_gmps_target(self, rpm_name: str) -> Optional[TargetMapping]:
        for pattern, dep_type in self.RPM_TO_GMPS_PATTERNS:
            if re.match(pattern, rpm_name):
                if dep_type == "pkg":
                    gmps_target = f"pkg-{rpm_name}"
                else:
                    gmps_target = rpm_name

                mapping = TargetMapping(
                    name=rpm_name,
                    target=gmps_target,
                    type=dep_type
                )
                self._rpm_mapping_cache[rpm_name] = mapping
                return mapping

        return None

    def query_gmps_dep_tree(self, phony_target: str = "", with_gmk: bool = False) -> Dict[str, List[str]]:
        dep_tree = {}
        if not phony_target:
            phony_target = self.top_target
        try:
            result = subprocess.run(
                [str(self._gms_deps_tree), "--target", phony_target, "--with-gmk" if with_gmk else ""],
                capture_output=True,
                text=True,
                check=False
            )

            if result.returncode != 0:
                raise RuntimeError(f"gms_deps_tree failed: {result.stderr}")

            lines = result.stdout.splitlines()
            json_start = -1
            for i, line in enumerate(lines):
                if line.strip().startswith('{'):
                    json_start = i
                    break
            if json_start == -1:
                raise RuntimeError(f"Failed to find JSON start in gms_deps_tree output")
            json_data = lines[json_start:]
            data = json.loads('\n'.join(json_data))
            for key, deps in data.items():
                if key in ('target', 'type'):
                    continue
                if isinstance(deps, list):
                    dep_tree[key] = deps

            self._gmps_targets = dep_tree
            if not dep_tree:
                # go target no deps in GMPS
                DEBUG(f"No targets found in GMPS dependency tree for {phony_target}")
            return dep_tree

        except json.JSONDecodeError as e:
            raise RuntimeError(f"Failed to parse gms_deps_tree output: {e}")
        except Exception as e:
            raise RuntimeError(f"Error querying GMPS targets: {e}")

    def expand_target_deps(self, target: str, dep_tree: Dict[str, List[str]],
                          visited: Optional[Set[str]] = None) -> Set[str]:
        if visited is None:
            visited = set()
        if target in visited:
            return set()

        visited.add(target)
        all_deps = set()
        direct_deps = dep_tree.get(target, [])
        for dep in direct_deps:
            if dep in dep_tree:
                all_deps.update(self.expand_target_deps(dep, dep_tree, visited))
            else:
                all_deps.add(dep)

        return all_deps

    def _get_rpms_all(self) -> Set[str]:
        required_rpms = set()
        img_repo_path = Path(REPO_TOP, "reg_container_tooling")
        yum_repo = self._yum_repo_inst()
        if yum_repo is None:
            raise RuntimeError("YumRepo not initialized, can not perform RPM check")

        for img in self.rpm_oth.keys():
            if self.type_map.get(img) != DepTypes.IMG:
                continue
            img_config = yum_repo.get_image_config(img)
            if not img_config or not img_config.docker_source_path:
                WARN(f"Image '{img}' missing docker_source_path in config")
                continue
            rpms = parse_install_guide(img_repo_path / img_config.docker_source_path / 'installGuide.in')
            rpms = {rpm for rpm in rpms if self.is_internal_rpm(rpm)}
            required_rpms.update(rpms)
            DEBUG(f"[{img:<17s}] requires: {' '.join(rpms)}")
        return required_rpms

    def _get_rpms_all_cache(self) -> Set[str]:
        required_rpms = set()
        for _, rpms in self.rpm_oth.items():
            for rpm_name in rpms.keys():
                if self.is_internal_rpm(rpm_name):
                    required_rpms.add(rpm_name)

        return required_rpms

    def check_dependency_completeness(self, new_target: bool ) -> Tuple[Set[str], Set[str], Set[str]]:
        dep_tree = self.query_gmps_dep_tree()
        if not dep_tree:
            raise RuntimeError(f"Failed to get target dependency tree from GMPS")

        required_rpms = set()
        for rpm_name in self._get_rpms_all():
            # IMSPhtppd -> phIMSPhtppd+pkg
            build_target = f"ph{rpm_name}"
            if build_target in dep_tree[self.pkg_target]:
                required_rpms.add(rpm_name)
            else:
                WARN(f"RPM {rpm_name} build target {build_target} not found in GMPS dep tree")

        build_lib = set()
        build_exec = set()
        build_pkg = set()
        cache_lib = {p.stem.split(".",1)[0] for p in self._dep_path_lib.glob("lib*.dep.json")}
        cache_exec = {p.stem.split(".",1)[0] for p in self._dep_path_exec.glob("*.dep.json")}
        cache_pkg = {p.stem.split(".",1)[0] for p in self._dep_path_pkg.glob("IMS*.dep.json")}
        build_pkg = required_rpms - cache_pkg

        exec_targets = set()
        for rpm_name in required_rpms:
            build_target = set(dep_tree.get(f"ph{rpm_name}", []))
            exec = {t for t in build_target if not t.startswith("lib")}
            exec_targets.update((rpm_name, e) for e in exec)
            build_exec.update(exec - cache_exec)

        def process_exec_target(r, e):
            _ = r
            exec_tree = self.query_gmps_dep_tree(e, with_gmk=True)
            exec_lib = self.expand_target_deps(e, exec_tree)
            missing_exec_lib = exec_lib - cache_lib
            if missing_exec_lib:
                WARN(f"Missing library for {e}: {' '.join(missing_exec_lib)}")
                return exec_lib, True
            else:
                DEBUG(f"{e} has all library dependencies satisfied in cache")
                return exec_lib, False

        with ThreadPoolExecutor(max_workers=self._max_workers) as executor:
            futures = {executor.submit(process_exec_target, r, e): (r, e) for r, e in exec_targets}
            for future in as_completed(futures):
                exec_lib, has_missing = future.result()
                r, e = futures[future]
                build_lib.update(exec_lib)
                if has_missing and not new_target:
                    build_exec.add(e)
                    build_pkg.add(r)
        missing_lib = build_lib - cache_lib
        missing_exec = build_exec
        missing_pkg = build_pkg

        if missing_lib:
            DEBUG(f"Missing libs: {missing_lib}")
        if missing_exec or missing_pkg:
            WARN(f"Missing execs: {' '.join(sorted(missing_exec))}")
            WARN(f"Missing pkgs: {' '.join(sorted(missing_pkg))}")

        return missing_lib, missing_exec, missing_pkg

    def generate_build_script(self, targets: Dict[str, List[str]],output_path: Optional[str] = None) -> str:
        config = self._build_configs.get(self.build_system)
        if not config:
            raise ValueError(f"Unknown build system: {self.build_system}")
        if not targets:
            return ""

        script_lines = [
            "#!/bin/bash",
            "set -e",
            "",
            "# Auto-generated build script for missing dependency data",
            f"# Build system: {self.build_system}",
            f"# Generated at: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            "",
        ]

        script_lines.append("# Environment setup")
        if config.env_vars:
            for key, value in config.env_vars.items():
                script_lines.append(f"export {key}={value}")
        if Path(config.env_overrides).is_file():
            script_lines.append(f"source {config.env_overrides}")
        script_lines.append("")

        script_lines.append("# Pre-build setup")
        if config.pre_build_cmd:
            for t in targets["exec"]:
                script_lines.append(f"{config.pre_build_cmd} -cld".format(TARGET=t))
            for t in targets["pkg"]:
                script_lines.append(config.pre_build_cmd.format(TARGET=t))
        script_lines.append("")

        script_lines.append("# Build targets")
        for t in targets["exec"]:
            script_lines.append(f"{config.build_cmd} -cld".format(TARGET=t))
        for t in targets["pkg"]:
            script_lines.append(config.build_cmd.format(TARGET=t))
        script_lines.append("")

        script_lines.append(f"echo 'Build {' '.join(targets['exec'] + targets['pkg'])} successfully'")
        script_content = '\n'.join(script_lines)

        if output_path:
            output = Path(output_path)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(script_content)
            output.chmod(0o755)
            INFO(f"Build script written to {output_path}")

        return script_content

    def execute_build(self, targets: Dict[str, List[str]], dry_run: bool = False) -> bool:
        if not targets:
            return True

        script_path = Path(tempfile.gettempdir()) / f"build_deps_{int(time.time())}.sh"
        self.generate_build_script(targets, str(script_path))

        if dry_run:
            INFO(f"[DRY RUN] Would execute: {script_path}")
            print(script_path.read_text())
            return True

        try:
            result = subprocess.run(
                ["bash -x", str(script_path)],
                capture_output=True,
                text=True,
                check=False,
                cwd=str(self._ims_admin_path)
            )

            if result.returncode != 0:
                ERROR(f"Build failed: {result.stderr}")
                return False

            INFO("Build completed successfully")
            return True

        except Exception as e:
            ERROR(f"Build execution error: {e}")
            return False
        finally:
            if script_path.exists():
                script_path.unlink()

    def update_version_file(self, base_version: str, new_targets: Dict[str, str]) -> bool:
        """
        Version file format:
        - Line 1: Base version (e.g., IMSDL26030071.000)
        - Line 2: Dependency data hash
        - Remaining lines: New target entries (target_name git_hash)
        """
        try:
            ims_admin_repo = self._load_repo("ims_admin")
            default_hash = ""
            if ims_admin_repo:
                try:
                    default_hash = ims_admin_repo.head.commit.short_hexsha
                except Exception:
                    pass

            dep_hash = self._cache_digest()
            lines = [base_version, dep_hash]

            for target_name, git_hash in new_targets.items():
                if not git_hash:
                    git_hash = default_hash
                lines.append(f"{target_name} {git_hash}")

            content = '\n'.join(lines) + '\n'

            self._tm_version_file.parent.mkdir(parents=True, exist_ok=True)
            self._tm_version_file.write_text(content, encoding='utf-8')
            INFO(f"Version file updated: {base_version}, {len(new_targets)} new targets")
            return True

        except Exception as e:
            ERROR(f"Failed to update version file: {e}")
            return False

    def parse_version_file(self) -> Tuple[str, str, Dict[str, str]]:
        if not self._tm_version_file.exists():
            return "", "", {}

        try:
            lines = self._tm_version_file.read_text(encoding='utf-8').strip().split('\n')
            base_version = lines[0] if len(lines) > 0 else ""
            dep_hash = lines[1] if len(lines) > 1 else ""
            new_targets = {}
            for line in lines[2:]:
                parts = line.split()
                if len(parts) >= 2:
                    new_targets[parts[0]] = parts[1]

            return base_version, dep_hash, new_targets

        except Exception as e:
            ERROR(f"Failed to parse version file: {e}")
            return "", "", {}

    def auto_complete_dependencies(self, dry_run: bool = False) -> Dict[str, Any]:
        missing_lib, missing_exec, missing_pkg = self.check_dependency_completeness(self.new_target)
        if not missing_exec and not missing_pkg:
            return {
                'status': True,
                'detail': "All dependencies are complete",
            }

        build_targets = {"exec": list(missing_exec), "pkg": list(missing_pkg)}
        INFO(f"Need to build {sum(len(v) for v in build_targets.values())} targets for incomplete RPMs")
        if dry_run:
            script = self.generate_build_script(build_targets)
            INFO(f"[DRY RUN] Would execute build with: {script}")
            return {
                'status': True,
                'detail': "[DRY RUN] Build script generated",
            }

        if not self.execute_build(build_targets):
            return {
                'status': False,
                'detail': "Build failed",
            }

        base_version, _, existing_targets = self.parse_version_file()
        new_targets = dict(existing_targets)
        for build_target in build_targets:
            # Will use default ims_admin hash
            new_targets[build_target] = ""
        self.update_version_file(base_version, new_targets)

        return {
            'status': True,
            'detail': "Built targets successfully",
        }


class RepoChange(TargetManager):
    """
    Repository change detector and update determiner.

    Inherits from TargetManager to:
    1. Load and manage dependency data (from DependencyDAG)
    2. Check and fix dependency completeness (from TargetManager)
    3. Detect repository changes since version tag
    4. Determine which RPMs/images need to be updated

    Workflow: Load Data -> Check/Fix -> Detect Changes -> Determine Updates
    """

    def __init__(self, auto_complete: bool = False):
        super().__init__()
        self.changed_files: Dict[str, List[str]] = defaultdict(list)
        self._auto_complete = auto_complete

    def get_update(self, dry_run: bool = False, skip_rpm_check: bool = False):
        """
        Get updates with optional auto-completion of missing dependencies.

        When auto_complete is enabled:
        1. First checks dependency completeness against GMPS build system
        2. If incomplete, triggers builds for missing targets
        3. Refreshes dependency cache
        4. Then proceeds with normal update check
        """
        self.build_dag()
        if self._auto_complete:
            DEBUG("Checking dependency completeness before update check...")
            result = self.auto_complete_dependencies(dry_run)
            if result['status'] and not dry_run:
                INFO("Refreshing dependency data after build...")
                self.build_dag()
        return self.check_all_repos(skip_rpm_check=skip_rpm_check)

    def load_digest(self) -> bool:
        digest_file = Path(self._pos_prefix_cache, "digest.dep.json")
        if not digest_file.exists():
            return False

        try:
            with open(digest_file, 'r') as f:
                loaded_digest = json.load(f)
            for repo, files in loaded_digest.items():
                self.digest_ignore[repo].update(files)
            for r, f in self.digest_ignore.items():
                INFO(f"Loaded ignore files digest {r} {f.keys()}")
            return True
        except Exception as e:
            ERROR(f"Failed to load digest file: {e}")
            return False

    def find_tag(self, repo: Repo, version_pattern: str) -> Optional[str]:
        repo_name = str(repo.working_dir).rsplit('/', 1)[-1]
        try:
            tags = repo.tags
            matching_tags = [tag for tag in tags if version_pattern in tag.name]
            if not matching_tags:
                WARN(f"[{repo_name}] No tags found matching pattern: {version_pattern}")
                return None
            sorted_tags = sorted(matching_tags, key=lambda t: t.commit.committed_date, reverse=True)
            latest_tag = sorted_tags[0].name
            return latest_tag
        except Exception as e:
            ERROR(f"Error finding tag: {e}")
            return None

    def git_changed(self, repo: Repo, tag_name: str) -> List[str]:
        """Get list of changed files between tag and current HEAD

        Handles all change types:
        - A: Added (new file)
        - D: Deleted (file removed)
        - M: Modified (file changed)
        - R: Renamed (file moved/renamed)
        - C: Copied
        - T: Type changed
        """
        try:
            diffs = repo.commit(tag_name).diff(repo.head.commit)
            changed_files = []
            for diff in diffs:
                # A (Added), M (Modified), T (Type changed): use b_path (new path)
                if diff.change_type in ['A', 'M', 'T']:
                    if diff.b_path:
                        changed_files.append(diff.b_path)
                # D (Deleted): use a_path (old path before deletion)
                elif diff.change_type == 'D':
                    if diff.a_path:
                        changed_files.append(diff.a_path)
                # R (Renamed): include both old and new paths
                elif diff.change_type == 'R':
                    if diff.a_path:
                        changed_files.append(diff.a_path)  # Old path (like deletion)
                    if diff.b_path:
                        changed_files.append(diff.b_path)  # New path (like addition)
                # C (Copied): use b_path (new copy)
                elif diff.change_type == 'C':
                    if diff.b_path:
                        changed_files.append(diff.b_path)
                # Fallback for unknown types
                else:
                    if diff.b_path:
                        changed_files.append(diff.b_path)
                    elif diff.a_path:
                        changed_files.append(diff.a_path)

            change_types = {}
            for diff in diffs:
                change_types[diff.change_type] = change_types.get(diff.change_type, 0) + 1
            type_summary = ", ".join([f"{k}:{v}" for k, v in sorted(change_types.items())])
            DEBUG(f"Found {len(changed_files)} changed files since tag {tag_name} ({type_summary})")
            return changed_files
        except Exception as e:
            ERROR(f"Error getting changed files: {e}")
            return []

    def repo_changes(self, repo_name: str) -> None:
        repo_path = Path(REPO_TOP, repo_name)
        try:
            repo = Repo(repo_path)
        except InvalidGitRepositoryError:
            WARN(f"{repo_name}: not a git repository")
            return

        # Extract version number from full version string
        # e.g., "IMSDL26030071.000" -> "26030071"
        version_pattern = self.version
        for prefix in ["IMSDL"]:
            if version_pattern.startswith(prefix):
                version_pattern = version_pattern[len(prefix):]
                break
        if "." in version_pattern:
            version_pattern = version_pattern.split(".")[0]

        tag_name = self.find_tag(repo, version_pattern)
        if not tag_name:
            return
        INFO(f"[{repo_name}] Using {tag_name} to find changes")
        changed_files = self.git_changed(repo, tag_name)
        if changed_files:
            self.changed_files[repo_name] = changed_files
            source_files = [f for f in changed_files if not f.endswith((".xml",".yang"))]
            INFO(f"[{repo_name}] {len(source_files)} changed: {' '.join(source_files)}")
        else:
            INFO(f"[{repo_name}] No changes found")

    def check_all_repos(self, skip_rpm_check: bool = False) -> Dict[str, Set[str]]:
        name_len = 0
        self.load_digest()
        # self.repo will populated by build_dag
        for repo_name in sorted(self.repo):
            if len(repo_name) > name_len:
                name_len = len(repo_name)
            self.repo_changes(repo_name)

        affected_imgs = set()
        affected_pkgs = set()
        for repo_name, files in self.changed_files.items():
            INFO(f"Processing [{repo_name:<{name_len}}] with {len(files)} changed files")
            for file in files:
                full_path = f"{repo_name}/{file}"
                imgs, pkgs, _, _ = self.affected_images(full_path)
                affected_imgs.update(imgs)
                affected_pkgs.update(pkgs)

        result = {
            "img": affected_imgs if skip_rpm_check else self.affected_images_rpm(affected_imgs),
            "pkg": affected_pkgs
        }

        INFO(f"Found {len(affected_imgs)} affected images and {len(affected_pkgs)} affected packages")
        return result


if __name__ == "__main__":
    def bool_arg(v):
        return v.lower() in ("yes", "true", "y", "1")
    import argparse
    parser = argparse.ArgumentParser(description="Dependency Analysis Tool for GMPS Project")
    parser.add_argument("--changes", nargs="+", help="List of changed files to analyze", default=[])
    parser.add_argument("--create-cache", type=str, help="Create dependency cache after loading")
    parser.add_argument("--check-update", action="store_true", help="Check repository changes since version tag and find affected images")
    parser.add_argument("--check-rpm-update", action="store_true", help="Check for RPM updates in all images by querying yum repositories")
    parser.add_argument("--skip-rpm-check", action="store_true", help="Skip RPM version check when using --check-update (only check file changes)")
    parser.add_argument("--lock-rpm", nargs="?", const="", help="Output RPM lock info for all images, or use provided file to check updates")
    parser.add_argument("--new-target", type=bool_arg, default=True,
                       help="Check dependency data completeness against GMPS build system")
    parser.add_argument("--check-deps", type=bool_arg, default=True,
                       help="Check dependency data completeness against GMPS build system")
    args = parser.parse_args()

    version = args.create_cache
    cache_action = CacheActions.CREATE if version else CacheActions.USE
    depStyle: Type[DependencyDAG] = TargetManager if args.check_deps else DependencyDAG
    if cache_action == CacheActions.CREATE:
        dag = depStyle(cache_action)(version)
    elif args.changes:
        dag = depStyle()
        dag.build_dag()
        print("Checking input changes...")
        changes_list = defaultdict(set)
        imgs, pkgs, _, _ = dag.affected_images_all(args.changes)
        changes_list["img"].update(imgs)
        changes_list["pkg"].update(pkgs)
        print(json.dumps(changes_list, indent=2))
    elif args.check_update:
        print("Checking repository changes...")
        changes_list = RepoChange(True).get_update(dry_run=True, skip_rpm_check=args.skip_rpm_check)
        for k, v in changes_list.items():
            print(f"{k}: {' '.join(v)}")
    elif args.check_rpm_update:
        dag = depStyle()
        dag.build_dag()
        print("Checking RPM updates in all images...")
        imgs, _, _, _ = dag.affected_images_all([])
        print(f"Update images: {imgs}")
    elif args.lock_rpm is not None:
        dag = depStyle()
        dag.build_dag()
        output_dir = "rpm_info"
        dag.lock_rpm_info(args.lock_rpm, output=output_dir)
        print(f"Outputting RPM lock information in {output_dir}")
    else:
        parser.print_help()

