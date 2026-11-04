# RDS (다른 AWS 계정) 연결

[← README로 돌아가기](../README.md)

DB는 메인 계정(A)이 아닌 **계정 B**의 RDS PostgreSQL을 씁니다. RDS와 보안그룹은 계정 B에
이미 구성되어 있고, Terraform/Ansible 모두 계정 B 리소스를 건드리지 않습니다.
Ansible은 **접속 정보 주입 + 연결 검사**만 합니다.

## 전제 (계정 B에 구성되어 있어야 하는 것)

- RDS **퍼블릭 액세스: 예** (계정이 달라 VPC/보안그룹을 공유할 수 없고, SSAFY 제공 EC2라 VPC 피어링도 불가)
- RDS 보안그룹 인바운드: `TCP 5432` ← **EC2 퍼블릭 IP/32**
- 앱 전용 DB 사용자 (마스터 계정을 앱에 쓰지 않기)

EC2 퍼블릭 IP는 `server.yml` 연결 실패 메시지에 출력되며, 직접 확인하려면
`ssh ... curl -s https://checkip.amazonaws.com`. EC2 IP가 바뀌면 보안그룹도 같이 바꿔야 합니다.

## 이 저장소 설정

`group_vars/all.yml`

```yaml
db_host: loom-db.xxxxxxxxxxxx.ap-northeast-2.rds.amazonaws.com
db_port: 5432
db_name: loom
db_user: loom
db_sslmode: require        # 인증서 검증까지 하려면 verify-full + RDS CA 번들 마운트
check_db_connectivity: true
```

`group_vars/vault.yml`: `vault_db_password`

Spring에는 다음 환경변수로 전달됩니다 (`templates/app.env.j2`). Spring Boot의 relaxed binding으로
`application.properties`에 따로 적지 않아도 `spring.datasource.*`에 바인딩됩니다.

```
SPRING_DATASOURCE_URL=jdbc:postgresql://<host>:5432/loom?sslmode=require
SPRING_DATASOURCE_USERNAME=loom
SPRING_DATASOURCE_PASSWORD=...
```

## 연결 검사

`server.yml`은 컨테이너를 띄우기 전에 EC2에서 `db_host:db_port`로 TCP 연결을 시도하고,
실패하면 EC2 퍼블릭 IP와 함께 원인을 안내하며 중단합니다.

## 주의

- RDS가 인터넷에 노출되므로 **보안그룹 IP 제한, TLS, 강한 비밀번호**는 필수입니다.
- 계정 간 트래픽은 인터넷 경유라 데이터 전송 비용이 발생할 수 있습니다. 같은 리전(ap-northeast-2)에 두세요.
