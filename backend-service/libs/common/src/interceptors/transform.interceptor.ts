import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { Observable, map } from 'rxjs';
import { ApiResponseDto } from '../dto/api-response.dto';

interface HttpRequestLike {
  originalUrl?: string;
  url?: string;
}

@Injectable()
export class TransformInterceptor<T> implements NestInterceptor<
  T,
  ApiResponseDto<T> | T
> {
  intercept(
    context: ExecutionContext,
    next: CallHandler<T>,
  ): Observable<ApiResponseDto<T> | T> {
    const request = context.switchToHttp().getRequest<HttpRequestLike>();

    const path = (request.originalUrl ?? request.url ?? '').split('?')[0];

    /*
     * Prometheus exposition endpoints must remain raw text.
     * Never wrap /metrics or /vN/metrics in the JSON API envelope.
     */
    const isMetricsEndpoint =
      path === '/metrics' || /^\/v\d+\/metrics$/.test(path);

    if (isMetricsEndpoint) {
      return next.handle();
    }

    return next.handle().pipe(
      map((data) => ({
        success: true,
        data,
        timestamp: new Date().toISOString(),
      })),
    );
  }
}
