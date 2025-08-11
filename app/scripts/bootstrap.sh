#!/usr/bin/env bash
set -euo pipefail

# Run within /app
if [ ! -f artisan ]; then
  composer create-project laravel/laravel:^11.0 .
fi

# Dependencies
composer require laravel/breeze:^2.2 predis/predis guzzlehttp/guzzle --no-interaction --no-ansi

# Breeze install (Blade)
if [ ! -d resources/views/auth ]; then
  php artisan breeze:install blade --no-interaction
fi

# Ensure queue connection default to redis in .env.example
if ! grep -q '^QUEUE_CONNECTION=' .env.example; then
  echo 'QUEUE_CONNECTION=redis' >> .env.example
else
  sed -i 's/^QUEUE_CONNECTION=.*/QUEUE_CONNECTION=redis/' .env.example
fi

# Add example env keys
add_key() {
  local key="$1"
  grep -q "^${key}=" .env.example || echo "${key}=" >> .env.example
}
add_key DATABASE_URL
add_key REDIS_URL
add_key FILESYSTEM_DISK
sed -i 's/^FILESYSTEM_DISK=.*/FILESYSTEM_DISK=s3/' .env.example || true
add_key AWS_ACCESS_KEY_ID
add_key AWS_SECRET_ACCESS_KEY
add_key AWS_DEFAULT_REGION
add_key AWS_BUCKET
add_key TMDB_API_KEY
add_key OMDB_API_KEY
add_key CV_ANALYZER_URL

# Routes: healthz and photos
if ! grep -q "Route::get('/healthz'" routes/web.php; then
  cat >> routes/web.php <<'PHP'

use Illuminate\Support\Facades\Route;
use Illuminate\Http\Request;
use App\Http\Controllers\PhotoController;

Route::get('/healthz', function () {
    return response()->json(['ok' => true]);
});

Route::get('/photos', [PhotoController::class, 'index'])->name('photos.index');
Route::get('/photos/{photo}', [PhotoController::class, 'show'])->name('photos.show');
PHP
fi

# Controller: PhotoController
if [ ! -f app/Http/Controllers/PhotoController.php ]; then
  mkdir -p app/Http/Controllers
  cat > app/Http/Controllers/PhotoController.php <<'PHP'
<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

class PhotoController extends Controller
{
    public function index()
    {
        return view('photos.index');
    }

    public function show($photoId)
    {
        return view('photos.show', ['photoId' => $photoId]);
    }
}
PHP
fi

# Views
mkdir -p resources/views/photos
if [ ! -f resources/views/photos/index.blade.php ]; then
  cat > resources/views/photos/index.blade.php <<'BLADE'
@extends('layouts.app')
@section('content')
<div class="container mx-auto p-6">
  <h1 class="text-2xl font-bold mb-4">Upload Photo</h1>
  <form method="post" enctype="multipart/form-data" action="#">
    @csrf
    <input type="file" name="photo" class="border p-2" />
    <button type="submit" class="ml-2 px-4 py-2 bg-blue-600 text-white">Upload</button>
  </form>
</div>
@endsection
BLADE
fi
if [ ! -f resources/views/photos/show.blade.php ]; then
  cat > resources/views/photos/show.blade.php <<'BLADE'
@extends('layouts.app')
@section('content')
<div class="container mx-auto p-6">
  <h1 class="text-2xl font-bold mb-4">Photo {{ $photoId }}</h1>
  <p>Details coming soon.</p>
</div>
@endsection
BLADE
fi

# Services
mkdir -p app/Services
cat > app/Services/CvAnalyzer.php <<'PHP'
<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;

class CvAnalyzer
{
    public function healthz(): bool
    {
        $base = rtrim(env('CV_ANALYZER_URL', ''), '/');
        if ($base === '') {
            return false;
        }
        try {
            $response = Http::timeout(3)->get($base . '/healthz');
            return $response->ok() && ($response->json('ok') === true);
        } catch (\Throwable $e) {
            return false;
        }
    }
}
PHP

cat > app/Services/Tmdb.php <<'PHP'
<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;

class Tmdb
{
    public function ping(): bool
    {
        $apiKey = env('TMDB_API_KEY');
        if (empty($apiKey)) {
            return false;
        }
        try {
            $response = Http::timeout(3)->get('https://api.themoviedb.org/3/configuration', [
                'api_key' => $apiKey,
            ]);
            return $response->ok();
        } catch (\Throwable $e) {
            return false;
        }
    }
}
PHP

# Job
mkdir -p app/Jobs
cat > app/Jobs/AnalyzePhoto.php <<'PHP'
<?php

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\Log;

class AnalyzePhoto implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public function handle(): void
    {
        Log::info('AnalyzePhoto job executed (no-op).');
    }
}
PHP

# Migrations (id + timestamps only)
add_migration_if_missing() {
  local table="$1"
  if ! ls database/migrations/*_create_${table}_table.php >/dev/null 2>&1; then
    php artisan make:migration create_${table}_table --create=${table}
    local file
    file=$(ls -1 database/migrations/*_create_${table}_table.php | tail -n1)
    # Overwrite with minimal schema
    cat > "$file" <<PHP
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('${table}', function (Blueprint $table) {
            $table->id();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('${table}');
    }
};
PHP
  fi
}

add_migration_if_missing photos
add_migration_if_missing items
add_migration_if_missing titles

# Build assets
if [ -f package.json ]; then
  if command -v npm >/dev/null 2>&1; then
    npm ci --no-audit --no-fund
    npm run build
  fi
fi

# Generate app key if .env exists
if [ -f .env ]; then
  php artisan key:generate --force || true
fi