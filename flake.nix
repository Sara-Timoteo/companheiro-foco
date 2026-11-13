{
  description = "Focus Companion: also buildable and runnable with Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      perSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };

      pythonEnv = pkgs.python3.withPackages (ps: [ ps.paho-mqtt ]);

      libnoise = pkgs.stdenv.mkDerivation {
        pname = "libnoise-analyzer";
        version = "0.1.0";
        src = ./firmware/common;
        buildPhase = ''
          make lib CFLAGS="-O2 -std=c11 -Wall -Wextra -Werror -pedantic"
        '';
        doCheck = true;
        checkPhase = ''
          make test CFLAGS="-O2 -std=c11 -Wall -Wextra -Werror -pedantic -D_DEFAULT_SOURCE"
        '';
        installPhase = ''
          mkdir -p $out/lib
          cp libnoise_analyzer.so $out/lib/
        '';
      };

      sensorApp = pkgs.stdenv.mkDerivation {
        pname = "companheiro-foco-sensor";
        version = "0.1.0";
        src = ./sensor;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        installPhase = ''
          mkdir -p $out/app $out/bin
          cp focus_device.py $out/app/
          cp ${libnoise}/lib/libnoise_analyzer.so $out/app/
          makeWrapper ${pythonEnv}/bin/python $out/bin/focus-device \
            --set NOISE_LIB $out/app/libnoise_analyzer.so \
            --add-flags $out/app/focus_device.py
        '';
      };

      panelApp = pkgs.stdenv.mkDerivation {
        pname = "companheiro-foco-panel";
        version = "0.1.0";
        src = ./dashboard;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        installPhase = ''
          mkdir -p $out/app $out/bin
          cp server.py $out/app/
          cp -r static $out/app/static
          makeWrapper ${pythonEnv}/bin/python $out/bin/focus-panel \
            --chdir $out/app \
            --add-flags $out/app/server.py
        '';
      };

      nss = pkgs.runCommand "app-nss" { } ''
        mkdir -p $out/etc
        cat > $out/etc/passwd <<'PASSWD'
        root:x:0:0:root:/root:/noshell
        app:x:1000:1000:app:/app:/noshell
        nobody:x:65534:65534:nobody:/:/noshell
        PASSWD
        cat > $out/etc/group <<'GROUP'
        root:x:0:
        app:x:1000:
        nobody:x:65534:
        GROUP
        echo "hosts: files dns" > $out/etc/nsswitch.conf
        printf "127.0.0.1 localhost\n::1 localhost\n" > $out/etc/hosts
      '';

      # Broker healthcheck: prove 8883 presents the server certificate.
      # Not a full mTLS login (that would need a health client identity).
      health8883 = pkgs.writeShellApplication {
        name = "health-8883";
        runtimeInputs = [
          pkgs.openssl
          pkgs.gnugrep
          pkgs.coreutils
        ];
        text = ''
          # openssl exits non-zero after the server asks for a client cert.
          # Disable pipefail so a successful grep still counts as healthy.
          set +o pipefail
          openssl s_client -connect 127.0.0.1:8883 -CAfile /mosquitto/certs/ca.crt -brief \
            </dev/null 2>&1 | grep -E -q 'CN[[:space:]]*=[[:space:]]*mosquitto'
        '';
      };

      binSh = pkgs.runCommand "bin-sh" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.dash}/bin/dash $out/bin/sh
      '';

      imageRoot =
        paths:
        pkgs.buildEnv {
          name = "image-root";
          inherit paths;
          pathsToLink = [
            "/bin"
            "/etc"
          ];
        };

      extraImageDirs = ''
        mkdir -p tmp app mosquitto/config mosquitto/data mosquitto/log mosquitto/certs certs
        chmod 1777 tmp mosquitto/data mosquitto/log
      '';

      brokerImage = pkgs.dockerTools.buildLayeredImage {
        name = "companheiro-foco-broker";
        tag = "nix";
        contents = [
          (imageRoot [
            pkgs.mosquitto
            pkgs.coreutils
            pkgs.openssl
            pkgs.dash
            binSh
            health8883
            nss
          ])
        ];
        extraCommands = extraImageDirs;
        config = {
          User = "1000:1000";
          Env = [ "PATH=/bin" ];
          Cmd = [
            "mosquitto"
            "-c"
            "/mosquitto/config/mosquitto.conf"
          ];
          ExposedPorts = {
            "8883/tcp" = { };
          };
        };
      };

      sensorRoot = pkgs.runCommand "sensor-root" { } ''
        mkdir -p $out/app
        cp ${./sensor/focus_device.py} $out/app/focus_device.py
        cp ${libnoise}/lib/libnoise_analyzer.so $out/app/libnoise_analyzer.so
      '';

      sensorImage = pkgs.dockerTools.buildLayeredImage {
        name = "companheiro-foco-sensor";
        tag = "nix";
        contents = [
          (imageRoot [
            pythonEnv
            pkgs.coreutils
            nss
          ])
          sensorRoot
        ];
        extraCommands = extraImageDirs;
        config = {
          User = "1000:1000";
          WorkingDir = "/app";
          Env = [
            "PATH=/bin"
            "PYTHONDONTWRITEBYTECODE=1"
            "PYTHONUNBUFFERED=1"
            "NOISE_LIB=/app/libnoise_analyzer.so"
          ];
          Cmd = [
            "python"
            "focus_device.py"
          ];
        };
      };

      panelRoot = pkgs.runCommand "panel-root" { } ''
        mkdir -p $out/app/static
        cp ${./dashboard/server.py} $out/app/server.py
        cp -r ${./dashboard/static}/. $out/app/static/
      '';

      panelImage = pkgs.dockerTools.buildLayeredImage {
        name = "companheiro-foco-panel";
        tag = "nix";
        contents = [
          (imageRoot [
            pythonEnv
            pkgs.coreutils
            nss
          ])
          panelRoot
        ];
        extraCommands = extraImageDirs;
        config = {
          User = "1000:1000";
          WorkingDir = "/app";
          Env = [
            "PATH=/bin"
            "PYTHONDONTWRITEBYTECODE=1"
            "PYTHONUNBUFFERED=1"
          ];
          Cmd = [
            "python"
            "server.py"
          ];
          ExposedPorts = {
            "8443/tcp" = { };
          };
        };
      };

      policyJson = pkgs.writeText "policy.json" ''
        { "default": [ { "type": "insecureAcceptAnything" } ] }
      '';

      containerTools = [
        pkgs.podman
        pkgs.podman-compose
        pkgs.docker-compose
        pkgs.openssl
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.findutils
        pkgs.util-linux
        pkgs.conmon
        pkgs.crun
        pkgs.netavark
        pkgs.aardvark-dns
        pkgs.passt
        pkgs.slirp4netns
        pkgs.fuse-overlayfs
        pkgs.iptables
      ];

      repoGuard = ''
        if [[ ! -f compose.nix.yml || ! -x certs/gen-certs.sh || ! -f mosquitto/config/mosquitto.conf ]]; then
          echo "Run this from a companheiro-foco checkout (compose.nix.yml, certs/ and mosquitto/ must be present)." >&2
          exit 1
        fi
      '';

      dockerWrapped = pkgs.writeShellApplication {
        name = "docker";
        text = ''
          # Rootless podman maps container uid 1000 to a subuid, so host-mounted
          # 0600 certs are unreadable to --user $(id -u) unless we keep the host id.
          # Only used by the Nix path; the Docker compose path is unchanged.
          if [[ ''${1-} == run ]]; then
            shift
            exec ${pkgs.podman}/bin/podman run --userns=keep-id "$@"
          fi
          exec ${pkgs.podman}/bin/podman "$@"
        '';
      };

      podmanSetup = ''
        unset -f podman docker 2>/dev/null || true
        export PATH="${dockerWrapped}/bin:${pkgs.lib.makeBinPath containerTools}:$PATH"
        # Runtime conf lives under XDG_RUNTIME_DIR, never under the user's
        # ~/.config/containers. graphroot stays the usual per-user store.
        runtimeDir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        dataHome="''${XDG_DATA_HOME:-$HOME/.local/share}"
        confDir="$runtimeDir/companheiro-foco-containers"
        mkdir -p "$confDir"
        if [[ -S "$runtimeDir/bus" ]]; then
          cgroup_manager=systemd
        else
          cgroup_manager=cgroupfs
        fi
        cat > "$confDir/containers.conf" <<EOF
[engine]
cgroup_manager = "$cgroup_manager"
runtime = "crun"
conmon_path = ["${pkgs.conmon}/bin/conmon"]
helper_binaries_dir = [
  "${pkgs.podman}/libexec/podman",
  "${pkgs.aardvark-dns}/bin",
  "${pkgs.netavark}/bin",
  "${pkgs.crun}/bin",
  "${pkgs.passt}/bin",
  "${pkgs.slirp4netns}/bin"
]
[network]
network_backend = "netavark"
EOF
        cat > "$confDir/storage.conf" <<EOF
[storage]
driver = "overlay"
runroot = "$runtimeDir/containers"
graphroot = "$dataHome/containers/storage"
EOF
        export CONTAINERS_CONF="$confDir/containers.conf"
        export CONTAINERS_STORAGE_CONF="$confDir/storage.conf"
      '';

      composeBin = ''
        # Prefer podman-compose, which talks to the podman CLI. "podman compose"
        # uses docker-compose and needs a running podman user API socket.
        compose() { podman-compose -f compose.nix.yml "$@"; }
      '';

      ensureCerts = ''
        needed=(
          certs/out/ca.crt certs/out/ca.key
          certs/out/server.crt certs/out/server.key
          certs/out/sensor.crt certs/out/sensor.key
          certs/out/dashboard.crt certs/out/dashboard.key
          certs/out/web-ca.crt certs/out/web.crt certs/out/web.key
        )
        missing=0
        for f in "''${needed[@]}"; do
          if [[ ! -f "$f" ]]; then
            missing=1
            break
          fi
        done
        if [[ "$missing" -eq 1 ]]; then
          ./certs/gen-certs.sh --force
          ./certs/gen-web-cert.sh --force
        fi
        chmod 0700 mosquitto/config/acl
      '';

      # Load always so a rebuilt tarball replaces a stale tag. policy.json is
      # placed only in a temporary HOME for this command, not in ~/.config.
      loadImages = ''
        load_image() {
          local tar="$1" home
          home="$(mktemp -d)"
          mkdir -p "$home/.config/containers"
          cp ${policyJson} "$home/.config/containers/policy.json"
          HOME="$home" podman load -i "$tar"
          rm -rf "$home"
        }
        load_image ${brokerImage}
        load_image ${sensorImage}
        load_image ${panelImage}
      '';

      demo = pkgs.writeShellApplication {
        name = "demo";
        runtimeInputs = containerTools;
        text = ''
          set -euo pipefail
          ${repoGuard}
          ${podmanSetup}
          ${composeBin}
          ${loadImages}
          ${ensureCerts}
          uid="$(id -u)"; gid="$(id -g)"
          export HOST_UID="$uid" HOST_GID="$gid"
          compose up -d
          ok=0
          for _ in $(seq 1 60); do
            statuses="$(podman inspect --format '{{.State.Health.Status}}' focus-mosquitto focus-sensor focus-dashboard 2>/dev/null || true)"
            if echo "$statuses" | grep -q . && ! echo "$statuses" | grep -v -q '^healthy$'; then
              ok=1
              break
            fi
            sleep 2
          done
          if [[ "$ok" -ne 1 ]]; then
            echo "Stack did not become healthy." >&2
            podman ps -a || true
            podman logs focus-mosquitto || true
            podman logs focus-sensor || true
            podman logs focus-dashboard || true
            exit 1
          fi
          echo "Stack is healthy. Dashboard: https://localhost:8443"
        '';
      };

      demoDown = pkgs.writeShellApplication {
        name = "demo-down";
        runtimeInputs = containerTools;
        text = ''
          set -euo pipefail
          ${repoGuard}
          ${podmanSetup}
          ${composeBin}
          compose down --volumes || true
          podman rm -f focus-mosquitto focus-sensor focus-dashboard >/dev/null 2>&1 || true
          echo "Stack stopped."
        '';
      };

      testApp = pkgs.writeShellApplication {
        name = "test";
        runtimeInputs = containerTools;
        text = ''
          set -euo pipefail
          ${repoGuard}
          ${podmanSetup}
          ${composeBin}
          statuses="$(podman inspect --format '{{.State.Health.Status}}' focus-mosquitto focus-sensor focus-dashboard 2>/dev/null || true)"
          if ! echo "$statuses" | grep -q . || echo "$statuses" | grep -v -q '^healthy$'; then
            echo "The stack is not healthy. Run nix run .#demo first." >&2
            exit 1
          fi
          # Only trust PASS lines when the engine is really running and the
          # positive checks pass. A missing docker CLI makes negatives pass.
          # Use the Nix broker image as the MQTT client; do not retag
          # eclipse-mosquitto:2.
          export BROKER_TEST_IMAGE=companheiro-foco-broker:nix
          ./scripts/broker-smoke-test.sh
        '';
      };

      runtimeTree = pkgs.runCommand "companheiro-foco-runtime" { } ''
        mkdir -p $out/certs $out/scripts $out/mosquitto/config
        cp ${./compose.nix.yml} $out/compose.nix.yml
        cp ${./mosquitto/config/mosquitto.conf} $out/mosquitto/config/mosquitto.conf
        cp ${./mosquitto/config/acl} $out/mosquitto/config/acl
        cp ${./certs/gen-certs.sh} $out/certs/gen-certs.sh
        cp ${./certs/gen-web-cert.sh} $out/certs/gen-web-cert.sh
        cp ${./scripts/broker-smoke-test.sh} $out/scripts/broker-smoke-test.sh
        chmod +x $out/certs/*.sh $out/scripts/*.sh
      '';

      demoTest =
        pkgs.testers.runNixOSTest {
          name = "companheiro-foco-demo";
          nodes.machine = {
            virtualisation.memorySize = 3072;
            virtualisation.diskSize = 4096;
            virtualisation.cores = 2;
            virtualisation.podman.enable = true;
            virtualisation.podman.dockerCompat = true;
            virtualisation.podman.defaultNetwork.settings.dns_enabled = true;
            environment.systemPackages = [
              pkgs.podman-compose
              pkgs.docker-compose
              pkgs.openssl
              pkgs.curl
              pkgs.netcat
            ];
          };
          testScript = ''
            start_all()
            machine.wait_for_unit("multi-user.target")
            machine.succeed("cp -a ${runtimeTree}/. /tmp/cf/")
            machine.succeed("cd /tmp/cf && chmod 0700 mosquitto/config/acl && ./certs/gen-certs.sh && ./certs/gen-web-cert.sh")
            machine.succeed("podman load -i ${brokerImage}")
            machine.succeed("podman load -i ${sensorImage}")
            machine.succeed("podman load -i ${panelImage}")
            # Rootful podman in the VM: do not use keep-id, and do not run
            # mosquitto as root (it would exit at once).
            machine.succeed(
              "cd /tmp/cf && chown -R 1000:1000 certs mosquitto && chmod 0700 mosquitto/config/acl && "
              "printf '%s\n' "
              "'services:' "
              "'  mosquitto: { userns_mode: host }' "
              "'  sensor: { userns_mode: host }' "
              "'  dashboard: { userns_mode: host }' "
              "> compose.rootful.yml"
            )
            machine.succeed("cd /tmp/cf && HOST_UID=1000 HOST_GID=1000 podman-compose -f compose.nix.yml -f compose.rootful.yml up -d")
            machine.wait_until_succeeds(
              "podman inspect --format '{{.State.Health.Status}}' focus-mosquitto focus-sensor focus-dashboard | grep -cvx healthy | grep -qx 0",
              120,
            )
            machine.fail("nc -z 127.0.0.1 1883")
            machine.succeed("curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ | grep -qx 200")
            machine.succeed("cd /tmp/cf && BROKER_TEST_IMAGE=companheiro-foco-broker:nix ./scripts/broker-smoke-test.sh")
          '';
        };
        in
        {
          packages = {
        default = pkgs.symlinkJoin {
          name = "companheiro-foco";
          paths = [
            sensorApp
            panelApp
          ];
        };
        sensor = sensorApp;
        panel = panelApp;
        libnoise = libnoise;
        broker-image = brokerImage;
        sensor-image = sensorImage;
        panel-image = panelImage;
        demo = demo;
        demo-down = demoDown;
        test = testApp;
      };

          apps = {
        default = {
          type = "app";
          program = "${demo}/bin/demo";
        };
        demo = {
          type = "app";
          program = "${demo}/bin/demo";
        };
        demo-down = {
          type = "app";
          program = "${demoDown}/bin/demo-down";
        };
        test = {
          type = "app";
          program = "${testApp}/bin/test";
        };
      };

          devShells.default = pkgs.mkShell {
        packages = containerTools ++ [
          pythonEnv
          pkgs.gnumake
          pkgs.gcc
        ];
      };

          checks = {
            libnoise = libnoise;
            sensor = sensorApp;
            panel = panelApp;
            broker-image = brokerImage;
            sensor-image = sensorImage;
            panel-image = panelImage;
          };

          # Experimental: not wired into `nix flake check`.
          legacyPackages.vmTest = demoTest;
        };
    in
    {
      packages = forAllSystems (system: (perSystem system).packages);
      apps = forAllSystems (system: (perSystem system).apps);
      devShells = forAllSystems (system: (perSystem system).devShells);
      checks = forAllSystems (system: (perSystem system).checks);
      legacyPackages = forAllSystems (system: (perSystem system).legacyPackages);
    };
}
