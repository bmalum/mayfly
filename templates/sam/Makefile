# SAM copies CodeUri (the Mix project) to a scratch dir and calls this target
# there with ARTIFACTS_DIR set (BuildMethod: makefile). The release is built with
# the Mayfly ERTS layer, so no Docker is needed; your toolchain's OTP must match
# the layer (see .tool-versions / mix lambda.doctor).
build-Function:
	mix deps.get
	MIX_ENV=prod mix release lambda --overwrite
	cd _build/prod/rel/lambda && unzip -qo lambda.zip -d "$(ARTIFACTS_DIR)"
