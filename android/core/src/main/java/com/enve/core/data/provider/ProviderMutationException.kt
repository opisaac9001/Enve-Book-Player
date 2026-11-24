package com.enve.core.data.provider

class ProviderMutationException(val httpStatus: Int, message: String) : IllegalStateException(message)
