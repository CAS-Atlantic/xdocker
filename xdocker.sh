#!/bin/bash

set -e

EXIT_CODE=0
QEMU_USER_STATIC_VERSION="4.2-1"
TMPDIR="${PWD}/tmp"
mkdir -p ${TMPDIR}

LOCAL_BIN="${PWD}/bin"
GETENT="${LOCAL_BIN}/my_getent"

abspath() {             
	changed_dir="true"            
    pushd "$(dirname $1)" &> /dev/null || changed_dir="false"
	echo "${PWD}/$(basename $1)"
    [ "${changed_dir}" == "true" ] && popd &> /dev/null 
}

_concat_path() {
	echo $1 | sed 's+[^a-zA-Z0-9_-]++g' | awk '{print tolower($0)}'
}

init_getent() {
cat << EOF > my_getent.c
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>

int main (int argc, const char *argv[])
{
	uid_t uid = getuid();
	struct passwd *pwd = getpwuid(uid);
	struct group *grd = getgrgid(pwd->pw_gid);

	if (argc == 2)
	{
		switch (argv[1][0])
		{
			case 'u':   printf("%s\n",	pwd->pw_name);  return 0;
			case 'i':	printf("%u\n", uid);			return 0;
			case 'g':   printf("%u\n", pwd->pw_gid);   return 0;
			case 'n':   printf("%s\n",	grd->gr_name);  return 0;
			case 's':   printf("%s\n", pwd->pw_shell); return 0;
			default:    break;
		}
	}

	printf("Expected 1 argument in the form [u|i|g|n|s]");
	return 1;
}
EOF
}

compile_getent() {
	if [ ! -f ${GETENT} ]; then
		mkdir -p "$(dirname ${GETENT})"
		CC=$( which gcc )
		[ "$?" != "0" ] && CC=$( which clang ) || true

		if [ "$?" != "0" ]; then
			echo "Unable to find a C compiler, Exiting"
			exit 1
		fi

		init_getent
		${CC} my_getent.c -o "${GETENT}"
		rm my_getent.c
	fi
}

QEMU_ARCH=(
	"x86_64"
	"arm"
	"aarch64"
	"i386"
	"ppc64le"
	"s390x"
)

DEBIAN_ARCH=(
	"amd64"
	"armhf"
	"arm64"
	"i386"
	"ppc64el"
	"s390x"
)

DOCKER_ARCH=(
	"amd64"
	"arm32v7"
	"arm64v8"
	"i386"
	"ppc64le"
	"s390x"
)

_get_index_in_list() {
	item=""
	INDEX="-1"
	for items in $@
	do
		if [ "${INDEX}" == "-1" ]; then
			item=${items}
		elif [ "_${item}" != "_" ] && [ "_${items}" == "_${item}" ]; then
			echo "${INDEX}"
			return 0
		fi
		INDEX=$(( INDEX+1 ))
	done

	echo "-1"
	return 1
}

_get_arch_index() {
	INDEX="$(_get_index_in_list $1 "${QEMU_ARCH[*]}")"
	[ "${INDEX}" == "-1" ] && INDEX="$(_get_index_in_list $1 "${DEBIAN_ARCH[*]}")"
	[ "${INDEX}" == "-1" ] && INDEX="$(_get_index_in_list $1 "${DOCKER_ARCH[*]}")"
	echo "${INDEX}"
}

HOST_ARCH_INDEX="$(_get_arch_index "$(uname -m)")"
HOST_OS="$(uname -s)"

SHARE=""
OWNER="xdocker_${QEMU_ARCH[${HOST_ARCH_INDEX}]}"

BASE_TAG=""
USER_TAG=""
FINAL_TAG=""

CUSTOM_DOCKERFILE=""
CUSTOM_DOCKERFILE_DIR=""

compile_getent

# get the current user
U_USER=$(${GETENT} u)
U_UID=$(${GETENT} i)
U_GID=$(${GETENT} g)
U_GROUP=$(${GETENT} n)
U_SHELL=$(${GETENT} s)

YOUR_REPO=$(echo "${U_USER}" | awk '{print tolower($0)}')

TEMP_DIR=$(mktemp -d)
BUILD_CONTEXT_DIR="${TEMP_DIR}/build/"
mkdir -p ${BUILD_CONTEXT_DIR}
echo "TEMP: ${TEMP_DIR}"
echo ""

_help() {

echo "
	Usage: 
	xdocker [OPTIONS] <target architecture> <shared directory> [ <...> docker run cmd are passed through ]
	
		OPTIONS:
			-f|--file <custom dockerfile>	gives a custom dockerfile to build from. 
				This script only supports running ubuntu, but the version is pulled from your docker file
			--clean                         cleans up the docker images and container left behind

		ARGS:
			\"target architecture\" 		The desired architecture to chroot into.
			\"shared directory\" 			The directory to chroot into.

		Available Architecture:
"
	for (( i=0; i<${#QEMU_ARCH[@]}; i++ ))
	do
		printf "\t\t\t - "
		printf "${QEMU_ARCH[${i}]}\n${DEBIAN_ARCH[${i}]}\n${DOCKER_ARCH[${i}]}" | sort -u | tr '\n' ',' | sed 's/,/, /g'
		echo ""
	done
}

_error_arg() {
	EXIT_CODE=1
	echo "ERROR_ARGS: $*"
	_help
	_exit
}

_error() {
	EXIT_CODE=2
	echo "ERROR: $*"
	_exit
}

_exit() {
	exit ${EXIT_CODE}
}

_parse_or_set_default() {
	if [ "_$1" != "_" ]; then
		echo $1 
	else 
		echo $2
	fi
}

_prep_path() {
	if [ "_$1" != "_" ]; then 
		temp_input=$(abspath $1 | sed 's/ /\\ /g')
		if [ -e "${temp_input}" ]; then
			echo "${temp_input}"
		fi
	else
		echo ""
	fi
}

_is_subdirectory_of() {
	case $1 in
		$2) echo 0;;
		$2/*) echo 1;;
		*) echo 0;;
	esac
}

_make_mount_cmd() {

	for dir_i in $@
	do
		skip_it=0
		for dir_j in $@
		do
			skip_it=$(_is_subdirectory_of $dir_i $dir_j)
			[ -z ${skip_it} ] || break
		done
		[ -z ${skip_it} ] && printf " "
	done
}

_get_qemu_user_static_deb() {
	pushd $(mktemp -d)
	PACKAGE="qemu-user-static_${QEMU_USER_STATIC_VERSION}_${DEBIAN_ARCH[${HOST_ARCH_INDEX}]}.deb"
	URL="http://ftp.debian.org/debian/pool/main/q/qemu/${PACKAGE}"
	wget "${URL}"
	ar vx "${PACKAGE}"
	tar xvf data.tar.xz 
	mv usr/bin/* $1
	popd
}

_make_base_dockerfile() {

	COPY_QUEMU_INTRPRTR_DIRECTIVE=""
	if [ "${MY_ARCH_INDEX}" != "${HOST_ARCH_INDEX}" ]
	then
		# we need to run the interpretter if we are in a different target than host
		COPY_QUEMU_INTRPRTR_DIRECTIVE="COPY qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static /usr/bin/"
	fi

	CMD=""

	if [ "_${CUSTOM_DOCKERFILE}" != "_" ] && [ -f "${CUSTOM_DOCKERFILE}" ]
	then
        INPUT_FROM=$(awk -v IGNORECASE=1 '$1=="FROM" {print $2}' ${CUSTOM_DOCKERFILE})
		CMD=""
    else
        INPUT_FROM="ubuntu:18.04"
        CMD="CMD [ \"/bin/bash\" ]"
	fi

	IMAGE_FOUND="false"

	if [ "_${IMAGE_FOUND}" != "_true" ]
	then
		FROM_DIRECTIVE="${DOCKER_ARCH[${MY_ARCH_INDEX}]}/${INPUT_FROM}"
		docker pull "${FROM_DIRECTIVE}" && IMAGE_FOUND="true"
	fi

	if [ "_${IMAGE_FOUND}" != "_true" ]
	then
		FROM_DIRECTIVE="${QEMU_ARCH[${MY_ARCH_INDEX}]}/${INPUT_FROM}"
		docker pull "${FROM_DIRECTIVE}" && IMAGE_FOUND="true"
	fi
	
	if [ "_${IMAGE_FOUND}" != "_true" ]
	then
		FROM_DIRECTIVE="${DEBIAN_ARCH[${MY_ARCH_INDEX}]}/${INPUT_FROM}"
		docker pull "${FROM_DIRECTIVE}" && IMAGE_FOUND="true"
	fi

	if [ "_${IMAGE_FOUND}" != "_true" ]
	then
		_error_arg "unsupported arch for custom dockerfile \"${INPUT_FROM}\""
	fi

	echo -e "\
FROM ${FROM_DIRECTIVE}\n\
${COPY_QUEMU_INTRPRTR_DIRECTIVE}\n\
\n\
${CMD}\n\
" > ${TEMP_DIR}/Base.Dockerfile

	if [ "_${CUSTOM_DOCKERFILE}" != "_" ] && [ -f "${CUSTOM_DOCKERFILE}" ]
	then 
		sed 's/[fF][rR][oO][mM].*//g' ${CUSTOM_DOCKERFILE} >> ${TEMP_DIR}/Base.Dockerfile
		echo "" >> ${TEMP_DIR}/Base.Dockerfile
	fi
}

_build_base_dockerfile() {
	BASE_TAG="${OWNER}/${QEMU_ARCH[${MY_ARCH_INDEX}]}"
	docker build -t "${BASE_TAG}" -f ${TEMP_DIR}/Base.Dockerfile ${BUILD_CONTEXT_DIR}
}

_make_user_spec_dockerfile() {
	CMD="$(cat ${TEMP_DIR}/Base.Dockerfile | grep CMD)"
	echo -e "\
FROM ${BASE_TAG}\n\
ENV XDOCKER=${QEMU_ARCH[${MY_ARCH_INDEX}]}\n\
RUN groupadd -f -g ${U_GID} ${U_GROUP} || true\n\
RUN useradd -u ${U_UID} -g ${U_GID} -G ${U_GROUP} -m -s /bin/bash ${U_USER}\n\
${CMD}\n\
" > "${TEMP_DIR}/User.Dockerfile"
}

_build_user_spec_dockerfile() {
	USER_TAG="${BASE_TAG}_${YOUR_REPO}"
	docker build -t "${USER_TAG}" -f "${TEMP_DIR}/User.Dockerfile" "${BUILD_CONTEXT_DIR}"
}

_make_dir_spec_dockerfile() {
	CMD="$(cat ${TEMP_DIR}/Base.Dockerfile | grep CMD)"
	echo -e "\
FROM ${USER_TAG}\n\
RUN mkdir -p ${SHARE}\n\
WORKDIR ${SHARE}\n\
${CMD}\n\
" > ${TEMP_DIR}/Dir.Dockerfile
}

_build_dir_spec_dockerfile() {
	SHARE_CONCAT=$(_concat_path ${SHARE})
	FINAL_TAG="${USER_TAG}_${SHARE_CONCAT}"
	docker build -t ${FINAL_TAG} -f ${TEMP_DIR}/Dir.Dockerfile ${BUILD_CONTEXT_DIR}
}

_clean_docker() {

	docker rm -v $(docker ps -a -q) &> /dev/null
	docker volume rm $(docker volume ls -q -f dangling=true) &> /dev/null
	docker rmi $(docker images -f dangling=true) &> /dev/null

	echo -e "\nContainers Left -----------\n"
	docker ps -a
	echo -e "\nVolumes Left -----------\n"
	docker volume ls
	echo -e "\nImages Left -----------\n"
	docker images
}

###########################################
# begin

#######################
# input args
while true; do
	case $1 in
		-f|--file)
			if [ "_$2" != "_" ]; then
				CUSTOM_DOCKERFILE=$(abspath $2 | sed 's/ /\\ /g')
				if [ -e "${CUSTOM_DOCKERFILE}" ]; then
					CUSTOM_DOCKERFILE_DIR=$(dirname "${CUSTOM_DOCKERFILE}")
					echo "using a customized dockerfile: ${CUSTOM_DOCKERFILE}"
				else
					_error_arg "custom docker file is not valid: ${CUSTOM_DOCKERFILE}"
				fi
			else
				_error_arg "custom docker file is not passed in but flag is passed in"
			fi
			shift
			shift
		;;
		--clean)
			_clean_docker
		;;
		-h|--help)
			_help
			exit 0
		;;
		*)
			break;
		;;
	esac
done

if [ "_$1" == "_" ]; then
	_error_arg "target architecture is not passed in as argument"
else
	MY_ARCH_INDEX=$( _get_arch_index $1 )
	if [ "_${MY_ARCH_INDEX}" == "-1" ]; then
		_error_arg "target architecture $1 is not valid"
	else
		echo "using Arch ${QEMU_ARCH[${MY_ARCH_INDEX}]} on a ${QEMU_ARCH[${HOST_ARCH_INDEX}]} "
		shift
	fi
fi

if [ "_$1" == "_" ]; then
	_error_arg "Shared directory is not passed in as argument"
else
	if [ ! -d $1 ]; then
		_error_arg "Shared directory $1 does not exist"
	else
		SHARE=$(_prep_path $1)
		shift
	fi
fi


if [ "_${CUSTOM_DOCKERFILE_DIR}" != "_" ] && [ -d ${CUSTOM_DOCKERFILE_DIR} ]; then
	cp -r ${CUSTOM_DOCKERFILE_DIR}/* ./
	rm -f Dockerfile
fi

QEMU_BIN_DIR="/usr/bin"
if [ ! -e "/usr/bin/qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static" ]; then
	if ! touch ${QEMU_BIN_DIR}/qemu-test-file;
	then
		QEMU_BIN_DIR="${LOCAL_BIN}"
	else
		rm ${QEMU_BIN_DIR}/qemu-test-file
	fi
fi

if [ ! -e "${QEMU_BIN_DIR}/qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static" ]; then
	_get_qemu_user_static_deb ${QEMU_BIN_DIR}
fi
	
cp ${QEMU_BIN_DIR}/qemu-${QEMU_ARCH[${MY_ARCH_INDEX}]}-static ${TEMP_DIR}/build/

# register static binaries
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

_make_base_dockerfile
_build_base_dockerfile

_make_user_spec_dockerfile
_build_user_spec_dockerfile

_make_dir_spec_dockerfile
_build_dir_spec_dockerfile

rm -Rf ${TEMP_DIR}

echo "===============================
Docker images created for this build:
 - ${FINAL_TAG}
 - ${USER_TAG}
 - ${BASE_TAG}

--------------------------------
BE AWARE, If you are using an NFS mount with no_subtree_check, or defaults, you cannot mount an NFS subdirectory, only top level
consider adding 'subtree_check' to your nfs export to mount subdirectory
--------------------------------

Starting 
 image: ${FINAL_TAG} 
 mount: ${SHARE} 
 arch:  ${QEMU_ARCH[${MY_ARCH_INDEX}]}

"

EXEC=""
case ${HOST_OS} in
	Darwin)
		EXEC="docker run -it \
			--privileged \
			--cap-add=SYS_PTRACE \
			--security-opt seccomp=unconfined \
			-v ${SHARE}:${SHARE} \
			--user ${U_USER} \
			"$@" \
			${FINAL_TAG}"
		;;
	Linux)
		EXEC="docker run -it \
			--privileged \
			--cap-add=SYS_PTRACE \
			--security-opt seccomp=unconfined \
			--mount type=bind,source=${SHARE},target=${SHARE},bind-propagation=rshared \
			--user ${U_USER} \
			"$@" \
			${FINAL_TAG}"
		;;
	*)
		echo "Untested host! ${HOST_OS}, please consider submitting your result so we can improve"
		EXEC="docker run -it \
			--privileged \
			--cap-add=SYS_PTRACE \
			--security-opt seccomp=unconfined \
			--mount type=bind,source=${SHARE},target=${SHARE},bind-propagation=rshared \
			--user ${U_USER} \
			"$@" \
			${FINAL_TAG}"
		;;
esac

EXEC=$(echo ${EXEC} | tr -s "[:blank:]")
echo "STARTING #################### 
${EXEC}"

${EXEC}
EXIT_CODE=$?

echo "
EXITING ######################
"

exit ${EXIT_CODE}
